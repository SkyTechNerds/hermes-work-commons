#!/bin/bash
# hermes-work — postet einen Reply IN den Review-Kommentar-Thread (alle Repos).
# Token intern. Usage: review-reply.sh <owner/repo> <pr> <comment_id> <body...>
set -euo pipefail
[ "$#" -lt 4 ] && { echo "usage: review-reply.sh <owner/repo> <pr> <comment_id> <body...>" >&2; exit 2; }
REPO="$1"; PR="$2"; CID="$3"; shift 3; BODY="$*"
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
gh api -X POST "repos/$REPO/pulls/$PR/comments/$CID/replies" \
  -f body="$BODY" --jq '"REPLY-POSTED: " + .html_url'
