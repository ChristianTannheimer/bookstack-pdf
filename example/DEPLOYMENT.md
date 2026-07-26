# Deployment auf dem Server

BookStack als Redaktionssystem, gebrandete PDFs als Auslieferung. Kunden bekommen
keine Konten — jede Nacht landet ein aktuelles PDF im geteilten Nextcloud-Ordner.

## Aufbau

```
bookstack/
├── Dockerfile                          Custom-Image: BookStack + WeasyPrint
├── docker-compose.yml
├── .env.example                        → nach .env kopieren
├── custom-cont-init.d/
│   └── 99-bookstack-pdf-command        trägt EXPORT_PDF_COMMAND nach
├── config/                             persistentes Volume
│   └── bookstack-to-pdf/
│       ├── config.yaml                 Branding, deutsche Beschriftungen
│       └── assets/ebt-logo.png         ← Logo hier ablegen
├── export-handbuecher.sh               nächtlicher Export nach Nextcloud
└── handbuecher.conf.example            → nach handbuecher.conf kopieren
```

## Inbetriebnahme

```bash
cp .env.example .env && chmod 600 .env
$EDITOR .env                                   # APP_KEY, Passwörter
mkdir -p config/bookstack-to-pdf/assets
cp /pfad/zu/ebt-logo.png config/bookstack-to-pdf/assets/
chown -R 1000:1000 config

# Init-Skript muss root gehören und ausführbar sein, sonst überspringt s6 es
sudo chown root:root custom-cont-init.d/99-bookstack-pdf-command
chmod +x custom-cont-init.d/99-bookstack-pdf-command

docker compose build
docker compose up -d
docker compose logs -f bookstack
```

Beim allerersten Start existiert `/config/www/.env` noch nicht, wenn das
Init-Skript läuft. Dann steht im Log `.env existiert noch nicht`. Einmal
`docker compose restart bookstack`, danach passt es dauerhaft.

Prüfen, ob der Renderer greift:

```bash
docker compose exec bookstack grep EXPORT_PDF /config/www/.env
```

Erststart: Login `admin@admin.com` / `password` — sofort ändern.

## Caddy

```caddyfile
doku.energiebuchhaltung-tirol.at {
    import ebt_security_headers        # dein bestehendes Snippet
    encode zstd gzip
    reverse_proxy 127.0.0.1:6875
}
```

Öffentlich erreichbar muss der Host nur sein, wenn du unterwegs schreiben
willst. Reicht dir NetBird, nimm stattdessen dein `remote_ip`-Snippet und die
ganze Auth-Frage erledigt sich.

## Nächtlicher Export

```bash
cp handbuecher.conf.example handbuecher.conf
$EDITOR handbuecher.conf

cat > export.env <<'EOF'
BS_URL=https://doku.energiebuchhaltung-tirol.at
BS_TOKEN_ID=...
BS_TOKEN_SECRET=...
NC_URL=https://cloud.energiebuchhaltung-tirol.at
NC_USER=service-doku
NC_PASS=...
EOF
chmod 600 export.env

chmod +x export-handbuecher.sh
./export-handbuecher.sh          # erst manuell testen
```

API-Token: in BookStack unter Profil → API-Token. Der Benutzer braucht die
Rolle-Berechtigung „Export content". Für Nextcloud ein **App-Passwort**
verwenden, nicht das Login-Passwort.

Das Skript lädt unter `.name.pdf.part` hoch und verschiebt dann auf den
Zielnamen — dadurch sieht der Kunde nie eine halb hochgeladene Datei. Bei
kaputtem oder verdächtig kleinem PDF bleibt die alte Version stehen.

Systemd-Timer:

```ini
# /etc/systemd/system/bookstack-export.service
[Unit]
Description=BookStack Kundenhandbücher nach Nextcloud

[Service]
Type=oneshot
User=christian
WorkingDirectory=/opt/bookstack
ExecStart=/opt/bookstack/export-handbuecher.sh
```

```ini
# /etc/systemd/system/bookstack-export.timer
[Unit]
Description=Taeglicher Handbuch-Export

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now bookstack-export.timer
systemctl list-timers bookstack-export
```

Fehlschläge: das Skript endet mit Exit 1, `systemctl status` zeigt es.
Für aktive Benachrichtigung eine `OnFailure=`-Unit anhängen.

## Stolperfallen

**Watchtower kann dieses Image nicht aktualisieren.** Ein selbstgebautes Image
bekommt keine Upstream-Updates. Deshalb der wöchentliche Rebuild im GitHub-Actions-Workflow —
Watchtower zieht dann dein frisches `ghcr.io/...:latest`. Ohne den Rebuild
bleibt BookStack auf dem Stand vom Build-Tag stehen.

**bookstack-to-pdf ist ein sehr junges Projekt** (zwei Commits, ein Contributor,
keine Releases). Deshalb pinnt der Build auf einen Commit-SHA statt auf `main`.
Setz `B2PDF_REF` in der `.env` und als Repository-Variable in GitHub. Fällt das
Projekt weg, exportiert BookStack weiterhin — nur wieder mit dompdf ohne
Deckblatt. Kein harter Ausfall.

**Metadaten auf dem Deckblatt sind bewusst deaktiviert.** Der Renderer liest
Autor und Datum per Regex aus dem Export-HTML, und die Muster sind auf
englischen BookStack-Text ausgelegt. Bei deutscher Oberfläche greifen sie nicht,
und `%B` in `date_input_format` hängt zusätzlich an der System-Locale.
Willst du das Datum aufs Deckblatt, setz die BookStack-Sprache des
Export-Benutzers auf Englisch oder passe die Regexe an das tatsächliche
Export-HTML an.

**Include-Tags und Markdown-Export vertragen sich nicht.** Bei Seiten, die im
Markdown-Editor geschrieben wurden, liefert der Markdown-Export den Rohtext
inklusive `{{@42}}`. Für Kundenauslieferung nur PDF oder Contained-HTML
verwenden. Am saubersten: Standardeditor auf WYSIWYG stellen.

**Buch-Export zeigt sonst Tags auf jeder Seite.** Falls du mit Tags arbeitest,
das Theme-Override für `exports/parts/page-item.blade.php` aus dem
bookstack-to-pdf-README setzen, sonst wird jede Seite im PDF mit ihrer
Tag-Liste zugepflastert.

**Umgebungsvariablen der linuxserver-Images** solltest du gegen deren aktuelle
Doku prüfen (`DB_USER`/`DB_PASS` heißen dort gelegentlich anders als in älteren
Anleitungen). Wenn der Container beim Start über die DB-Verbindung meckert,
liegt es fast immer daran.

## Struktur in BookStack

- Regal **Grundlagen** → Buch *Bausteine*: Anmeldung, Passwort ändern, Dashboard
  bedienen, Alarme verstehen, Glossar
- Regal **pro Kunde** → Buch *Handbuch Energiebuchhaltung* mit Kapiteln:
  Einstieg (nur Includes), Ihre Anlagen (spezifisch), Auswertungen (Includes),
  Störungsfälle (gemischt)

Das Inhaltsverzeichnis im PDF entsteht aus dieser Struktur. Kapitel- und
Seitennamen also gleich so benennen, wie sie im PDF stehen sollen.
