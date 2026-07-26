#!/usr/bin/env bash
#
# Exportiert je Kunde ein Handbuch-PDF aus BookStack und legt es per WebDAV
# in den geteilten Nextcloud-Ordner. Ueberschreibt die bestehende Datei, damit
# geteilte Links stabil bleiben.
#
# Aufruf:  ./export-handbuecher.sh [pfad/zur/handbuecher.conf]
# Benoetigt: bash 4+, curl, jq
#
# Exit 0 = alles ok, Exit 1 = mindestens ein Export fehlgeschlagen.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${1:-$SCRIPT_DIR/handbuecher.conf}"
SECRETS="${BOOKSTACK_EXPORT_ENV:-$SCRIPT_DIR/export.env}"

# shellcheck source=/dev/null
[[ -f "$SECRETS" ]] && source "$SECRETS"

: "${BS_URL:?BS_URL fehlt (z.B. https://doku.energiebuchhaltung-tirol.at)}"
: "${BS_TOKEN_ID:?BS_TOKEN_ID fehlt}"
: "${BS_TOKEN_SECRET:?BS_TOKEN_SECRET fehlt}"
: "${NC_URL:?NC_URL fehlt (z.B. https://cloud.energiebuchhaltung-tirol.at)}"
: "${NC_USER:?NC_USER fehlt}"
: "${NC_PASS:?NC_PASS fehlt (Nextcloud-App-Passwort, nicht das Login-Passwort)}"

TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { printf '%s  FEHLER: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# Kodiert Pfadsegmente einzeln, damit Leerzeichen und Umlaute funktionieren,
# Schraegstriche aber Schraegstriche bleiben.
urlencode_path() {
    local path="$1" out="" seg
    local IFS='/'
    read -ra segments <<< "$path"
    for seg in "${segments[@]}"; do
        [[ -z "$seg" ]] && continue
        out+="/$(printf '%s' "$seg" | jq -sRr @uri)"
    done
    printf '%s' "${out#/}"
}

bs_api() {
    curl -sS --fail-with-body \
         --retry 3 --retry-delay 5 --max-time 300 \
         -H "Authorization: Token ${BS_TOKEN_ID}:${BS_TOKEN_SECRET}" \
         "$@"
}

errors=0
processed=0

while IFS='|' read -r slug target filename; do
    # Kommentare und Leerzeilen ueberspringen
    [[ -z "${slug// }" || "${slug#\#}" != "$slug" ]] && continue

    slug="${slug// /}"
    target="$(printf '%s' "$target" | sed -e 's/^ *//' -e 's/ *$//')"
    filename="$(printf '%s' "$filename" | sed -e 's/^ *//' -e 's/ *$//')"

    log "--- $slug"

    # 1. Buch-ID ueber den Slug aufloesen
    if ! book_json="$(bs_api "${BS_URL}/api/books?filter\[slug\]=${slug}" 2>&1)"; then
        fail "$slug: API nicht erreichbar - $book_json"
        ((errors++)); continue
    fi

    book_id="$(printf '%s' "$book_json" | jq -r '.data[0].id // empty')"
    if [[ -z "$book_id" ]]; then
        fail "$slug: kein Buch mit diesem Slug gefunden"
        ((errors++)); continue
    fi

    # 2. PDF exportieren
    pdf="$TMPDIR_RUN/${slug}.pdf"
    if ! bs_api -o "$pdf" "${BS_URL}/api/books/${book_id}/export/pdf"; then
        fail "$slug: PDF-Export fehlgeschlagen (Laravel-Log pruefen)"
        ((errors++)); continue
    fi

    # 3. Plausibilitaet - lieber die alte Datei stehen lassen als Muell hochladen
    if [[ ! -s "$pdf" ]] || [[ "$(head -c 4 "$pdf")" != "%PDF" ]]; then
        fail "$slug: Ergebnis ist kein gueltiges PDF, Upload uebersprungen"
        ((errors++)); continue
    fi
    size_kb=$(( $(stat -c%s "$pdf") / 1024 ))
    if (( size_kb < 10 )); then
        fail "$slug: PDF nur ${size_kb} KB - verdaechtig klein, Upload uebersprungen"
        ((errors++)); continue
    fi

    # 4. Upload unter Temporaernamen, dann verschieben.
    #    So ist die Zieldatei nie halb hochgeladen sichtbar.
    dav="${NC_URL}/remote.php/dav/files/$(urlencode_path "${NC_USER}")"
    remote_dir="$(urlencode_path "$target")"
    remote_file="$(printf '%s' "$filename" | jq -sRr @uri)"
    part_url="${dav}/${remote_dir}/.${remote_file}.part"
    final_url="${dav}/${remote_dir}/${remote_file}"

    if ! curl -sS --fail-with-body --retry 3 --retry-delay 5 --max-time 300 \
              -u "${NC_USER}:${NC_PASS}" \
              -T "$pdf" "$part_url" >/dev/null; then
        fail "$slug: Upload nach Nextcloud fehlgeschlagen (Zielordner vorhanden?)"
        ((errors++)); continue
    fi

    if ! curl -sS --fail-with-body --max-time 60 \
              -u "${NC_USER}:${NC_PASS}" \
              -X MOVE -H "Destination: ${final_url}" -H "Overwrite: T" \
              "$part_url" >/dev/null; then
        fail "$slug: MOVE auf Zieldateiname fehlgeschlagen"
        curl -sS -u "${NC_USER}:${NC_PASS}" -X DELETE "$part_url" >/dev/null || true
        ((errors++)); continue
    fi

    log "$slug: ${size_kb} KB nach ${target}/${filename}"
    ((processed++))

done < "$CONF"

log "Fertig: $processed erfolgreich, $errors fehlgeschlagen"
(( errors == 0 )) || exit 1
