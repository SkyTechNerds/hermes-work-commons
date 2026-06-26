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
    *JUMO*) TOKFILE=/etc/hermes-discord-listener/jumo.token ;;
    *)      TOKFILE=/etc/hermes-discord-listener/hank.token ;;
  esac
  export GH_TOKEN; GH_TOKEN="$(cat "$TOKFILE")"
elif [ -z "${GH_TOKEN:-}" ]; then
  export GH_TOKEN="$GITHUB_TOKEN"
fi
SHA="$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha)"
gh api -X POST "repos/$REPO/pulls/$PR/comments" \
  -f body="$MSG" -f commit_id="$SHA" -f path="$FILE" -F line="$LINE" -f side=RIGHT \
  --jq '"INLINE-POSTED: " + .html_url'
