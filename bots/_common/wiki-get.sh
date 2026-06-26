#!/bin/bash
# hermes-work — holt eine Datei live aus der Wiki-SMB-Share (Axiom 192.168.2.220) auf stdout.
# Unprivileged-LXC-kompatibel (kein Kernel-Mount). Usage: wiki-get.sh <pfad-im-vault>
set -uo pipefail
[ "$#" -lt 1 ] && { echo "usage: wiki-get.sh <pfad>" >&2; exit 2; }
TMP=$(mktemp)
trap "rm -f $TMP" EXIT
smbclient //192.168.2.220/wiki -A /etc/hermes-wiki-smb.auth -c "get \"$1\" $TMP" >/dev/null 2>&1 || exit 0
cat "$TMP" 2>/dev/null
