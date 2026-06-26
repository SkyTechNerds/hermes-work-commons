#!/bin/bash
# hermes-work — haengt EINEN Eintrag an log.md (fuer kleine Notizen ohne eigene Seite).
# Optionaler Detail-Text via stdin. Usage: wiki-log.sh <action> "<subject>"
set -uo pipefail
[ "$#" -lt 2 ] && { echo "usage: wiki-log.sh <action> <subject>   (detail via stdin optional)" >&2; exit 2; }
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="$1"; SUBJECT="$2"; DATE="$(date +%F)"
BODY="$(cat 2>/dev/null || true)"
TMP=$(mktemp)
"$DIR/wiki-get.sh" log.md > "$TMP" 2>/dev/null || true
{ printf '\n## [%s] %s | %s\n' "$DATE" "$ACTION" "$SUBJECT"; [ -n "$BODY" ] && printf '%s\n' "$BODY"; } >> "$TMP"
"$DIR/wiki-put.sh" "$TMP" "log.md" >/dev/null && echo "WIKI-LOG: [$DATE] $ACTION | $SUBJECT"
rm -f "$TMP"
