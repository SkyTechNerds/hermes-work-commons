#!/bin/bash
# hermes-work — generischer ZEILENGENAUER Inline-Review-Kommentar (ALLE Repos).
# Token + Head-Commit-SHA werden intern aufgeloest (der Agent baut nichts selbst).
# Usage: review-comment.sh <owner/repo> <pr> <file> <line> <message...>
set -euo pipefail
if [ "$#" -lt 5 ]; then
  echo "usage: review-comment.sh <owner/repo> <pr> <file> <line> <message...>" >&2
  exit 2
fi
REPO="$1"; PR="$2"; FILE="$3"; LINE="$4"; shift 4; MSG="$*"
# Vorgegebenes Env-Token (z. B. App-Installation-Token) hat Vorrang; sonst PAT laden.
if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  case "$REPO" in
    JUMO-GmbH-Co-KG/*) TOKFILE=/etc/hermes-discord-listener/jumo.token ;;
    *)                 TOKFILE=/etc/hermes-discord-listener/hank.token ;;
  esac
  export GH_TOKEN; GH_TOKEN="$(cat "$TOKFILE")"
elif [ -z "${GH_TOKEN:-}" ]; then
  export GH_TOKEN="$GITHUB_TOKEN"
fi
SHA="$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha)"
# Unsichtbarer Herkunfts-Marker an JEDES Inline-Finding. Ohne ihn haelt ai-reply im
# PAT-Modus (Bot und Mensch teilen einen Account) das eigene Finding faellschlich fuer
# einen menschlichen Kommentar und antwortet nicht mehr auf Rueckfragen dazu.
# Stabiler Fund-Schluessel (Datei:Zeile + Kurz-Hash der Aussage). Ohne Dedup postete
# der Logik-Review denselben Fund bei JEDEM Lauf erneut — die Check-Findings haben das
# ueber <!-- cm-inline:... --> laengst, der ai-review-Pfad hatte es nie (Test-PR #781:
# nach einem `recheck` stand der Off-by-one zweimal im Diff).
# BEWUSST ohne Text-Hash: das LLM formuliert denselben Fund bei jedem Lauf anders
# ("laeuft einen Schritt zu weit" vs "greift auf items[length] zu") -> ein Hash ueber
# die Aussage ergibt jedes Mal einen neuen Schluessel und dedupliziert nichts (im
# Test-PR #781 nachgewiesen). Datei+Zeile ist die gleiche Konvention wie bei
# <!-- cm-inline:check:file:line -->: ein zweiter Fund auf derselben Zeile ist
# praktisch immer derselbe Fund.
KEY="cm-ai:$FILE:$LINE"
if gh api "repos/$REPO/pulls/$PR/comments?per_page=100" --jq '.[].body' 2>/dev/null \
     | grep -qF "<!-- $KEY -->"; then
  echo "INLINE-SKIP: schon vorhanden ($KEY)"
  exit 0
fi
MSG="$MSG
<!-- codemole:bot -->
<!-- $KEY -->"
gh api -X POST "repos/$REPO/pulls/$PR/comments" \
  -f body="$MSG" -f commit_id="$SHA" -f path="$FILE" -F line="$LINE" -f side=RIGHT \
  --jq '"INLINE-POSTED: " + .html_url'
