#!/bin/bash
# hermes-work — geaenderte Dateien + Patch eines PR (fuer den Code-Review). Token intern.
# Gibt pro Datei den Patch-Hunk aus (mit Zeilennummern fuer review-comment.sh).
# Usage: pr-diff.sh <owner/repo> <pr>
set -euo pipefail
if [ "$#" -lt 2 ]; then
  echo "usage: pr-diff.sh <owner/repo> <pr>" >&2
  exit 2
fi
REPO="$1"; PR="$2"
case "$REPO" in
  *JUMO*) TOKFILE=/etc/hermes-discord-listener/jumo.token ;;
  *)      TOKFILE=/etc/hermes-discord-listener/hank.token ;;
esac
export GH_TOKEN; GH_TOKEN="$(cat "$TOKFILE")"
gh api "repos/$REPO/pulls/$PR/files?per_page=100" \
  --jq '.[] | "=== FILE: \(.filename) (+\(.additions)/-\(.deletions)) ===\n\(.patch // "(kein Text-Patch / binaer)")"'
