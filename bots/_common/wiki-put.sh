#!/bin/bash
# hermes-work — schreibt eine lokale Datei in die Wiki-SMB-Share (Axiom 192.168.2.220).
# Unprivileged-LXC-kompatibel (smbclient, kein Kernel-Mount). Legt fehlende Zielordner an.
# Usage: wiki-put.sh <lokale-datei> <ziel-pfad-im-vault>   (z.B. Resources/foo.md)
set -uo pipefail
[ "$#" -lt 2 ] && { echo "usage: wiki-put.sh <local-file> <vault-path>" >&2; exit 2; }
LOCAL="$1"; DEST="$2"
[ -f "$LOCAL" ] || { echo "lokale Datei fehlt: $LOCAL" >&2; exit 2; }
DIR=$(dirname "$DEST")
if [ "$DIR" != "." ] && [ -n "$DIR" ]; then
  smbclient //192.168.2.220/wiki -A /etc/hermes-wiki-smb.auth -c "mkdir \"$DIR\"" >/dev/null 2>&1 || true
fi
OUT=$(smbclient //192.168.2.220/wiki -A /etc/hermes-wiki-smb.auth -c "put \"$LOCAL\" \"$DEST\"" 2>&1)
echo "$OUT" | grep -qiE "putting" && echo "WIKI-PUT: $DEST" || { echo "WIKI-PUT-FEHLER: $OUT" | head -1; exit 1; }
