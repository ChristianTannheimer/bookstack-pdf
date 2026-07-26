# bookstack-pdf

BookStack mit gebrandetem PDF-Export: Deckblatt, Inhaltsverzeichnis, Kopf- und
Fußzeile, eigene Schriften. Basiert auf [linuxserver/bookstack](https://github.com/linuxserver/docker-bookstack)
und ergänzt [NETWAYS/bookstack-to-pdf](https://github.com/NETWAYS/bookstack-to-pdf)
samt WeasyPrint, angebunden über BookStacks `EXPORT_PDF_COMMAND`.

Standardmäßig rendert BookStack PDFs mit dompdf — funktional, aber ohne
Deckblatt und Inhaltsverzeichnis. Dieses Image ersetzt den Renderer.

```
ghcr.io/christiantannheimer/bookstack-pdf:latest
```

## Repo oder Server — was liegt wo

Das hier ist **nur der Image-Bau**. Alles mit echten Werten bleibt auf dem Server.

| Im Repo (öffentlich) | Auf dem Server (`/opt/bookstack`) |
|---|---|
| `Dockerfile` | `docker-compose.yml` mit echten Werten |
| `.github/workflows/build-image.yml` | `.env` — Passwörter, `APP_KEY` |
| `README.md`, `LICENSE` | `config/` — persistentes Volume, Logo, Branding |
| `example/` — Vorlagen zum Kopieren | `export.env`, `handbuecher.conf` — Kundendaten |

Die Ordner unter `config/` legst du **beim Deployen selbst an**, sie existieren
im Repo nicht. Das ist Absicht: dort landen Logo, Kundendaten und die Datenbank.

## Deployment

```bash
sudo mkdir -p /opt/bookstack && cd /opt/bookstack

# Vorlagen aus dem Repo holen
git clone https://github.com/christiantannheimer/bookstack-pdf.git /tmp/bsp
cp -r /tmp/bsp/example/. .
mv .env.example .env
mv handbuecher.conf.example handbuecher.conf

# Verzeichnisse anlegen, die es im Repo nicht gibt
mkdir -p config/bookstack-to-pdf/assets db
cp ~/ebt-logo.png config/bookstack-to-pdf/assets/
chown -R 1000:1000 config db

chmod 600 .env
$EDITOR .env                      # APP_KEY, DB-Passwörter, SMTP

# Init-Skript muss root gehören, sonst überspringt s6-overlay es
sudo chown root:root custom-cont-init.d/99-bookstack-pdf-command
chmod +x custom-cont-init.d/99-bookstack-pdf-command

docker compose up -d
docker compose restart bookstack  # erst jetzt existiert /config/www/.env
docker compose exec bookstack grep EXPORT_PDF /config/www/.env
```

Im Compose ist `image:` auf `ghcr.io/...` gesetzt, ohne `build:` — der Server
zieht das fertige Image, gebaut wird nur in Actions.

## Wann gebaut wird

Der Workflow prüft täglich um 04:17 UTC und baut nur bei echter Änderung:

- neuer Digest bei `lscr.io/linuxserver/bookstack:latest`
- neuer Commit auf `main` in `NETWAYS/bookstack-to-pdf`
- Push auf `Dockerfile` in diesem Repo
- manuell über *Run workflow* mit „force"

Die Stände des letzten Builds stecken als Labels (`at.ebt.base-digest`,
`at.ebt.b2pdf-sha`) im veröffentlichten Image. Kein State-File, kein
Commit-Rauschen. Ohne Änderung endet der Lauf nach etwa 20 Sekunden.

**`B2PDF_REF` musst du nirgends von Hand pflegen.** Der Workflow löst den
aktuellen Commit selbst auf und übergibt den SHA als Build-Arg — jedes Image ist
also auf einen konkreten Commit gepinnt, nicht auf ein wanderndes `main`. Der
SHA im Dockerfile-`ARG` ist nur der Default für lokale Builds:

```bash
docker build --build-arg B2PDF_REF=$(git ls-remote \
  https://github.com/NETWAYS/bookstack-to-pdf main | cut -f1) -t bookstack-pdf .
```

## Updates auf dem Server

Watchtower kann ein selbstgebautes Image nicht aus dem Upstream aktualisieren —
es zieht aber ganz normal dein `:latest` von ghcr, sobald der Workflow ein neues
gepusht hat. Damit ist die Kette geschlossen: Upstream ändert sich → Actions
baut → Watchtower zieht.

Wenn dir das zu automatisch ist, im Compose auf `:${GITHUB_RUN_NUMBER}` pinnen
und manuell hochziehen. Bei der Auth-relevanten Komponente ist das die
konservativere Wahl.

## Was das Image ändert

Gegenüber dem Basis-Image kommen dazu: Python 3, Pango, Fontconfig,
DejaVu- und Liberation-Schriften sowie ein venv unter
`/opt/bookstack-to-pdf/.venv`. Ein Build-Time-Smoke-Test schlägt fehl, wenn der
Renderer nicht startet — dann bricht der Build und nicht später der Export.

`EXPORT_PDF_COMMAND` wird nicht als Docker-Environment gesetzt, sondern per
Init-Skript in `/config/www/.env` geschrieben. Grund: PHP-FPM räumt die
Prozessumgebung standardmäßig auf, weshalb der Weg über die `.env` der
zuverlässige ist.

Fällt `bookstack-to-pdf` weg, exportiert BookStack weiterhin — dann wieder mit
dompdf ohne Deckblatt. Kein harter Ausfall.

## Stolperfallen

Siehe `example/` und den Abschnitt im Deployment-README. Kurzfassung:

- Deckblatt-Metadaten sind aus, weil die Regex-Muster englischen BookStack-Text
  erwarten
- Markdown-Export löst `{{@42}}`-Include-Tags nicht auf — für Kunden PDF oder
  Contained-HTML nehmen
- `bookstack-to-pdf` ist ein sehr junges Projekt (wenige Commits, ein
  Contributor, keine Releases)

## Lizenz

MIT, siehe [LICENSE](LICENSE). Das Image enthält Software Dritter unter eigenen
Lizenzen, dort aufgeführt.
