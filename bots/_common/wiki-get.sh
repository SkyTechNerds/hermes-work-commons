#!/bin/bash
# hermes-work — holt eine Datei live aus der Wiki-SMB-Share (Axiom 192.168.2.220) auf stdout.
# Unprivileged-LXC-kompatibel (kein Kernel-Mount). Usage: wiki-get.sh <pfad-im-vault>
set -uo pipefail
[ "$#" -lt 1 ] && { echo "usage: wiki-get.sh <pfad>" >&2; exit 2; }
TMP=$(mktemp)
trap "rm -f $TMP" EXIT
# Der Vault wurde umsortiert: die Fachseiten liegen inzwischen unter company-wiki/.
# Deshalb beide Layouts probieren, statt still leer auszugehen — genau das passierte
# ab dem Umzug: ai-review fiel unbemerkt auf seine Kurz-Regelliste zurueck.
fetch() { smbclient //192.168.2.220/wiki -A /etc/hermes-wiki-smb.auth -c "get \"$1\" $TMP" >/dev/null 2>&1 && [ -s "$TMP" ]; }
if fetch "$1" || fetch "company-wiki/$1"; then
  cat "$TMP" 2>/dev/null
else
  # NICHT still scheitern: der Aufrufer sieht sonst nur eine leere Ausgabe.
  echo "wiki-get: '$1' nicht gefunden (weder direkt noch unter company-wiki/)" >&2
  exit 0
fi
