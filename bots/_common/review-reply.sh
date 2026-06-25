#!/bin/bash
# hermes-work — postet einen Reply IN den Review-Kommentar-Thread (alle Repos).
# Token intern. Usage: review-reply.sh <owner/repo> <pr> <comment_id> <body...>
set -euo pipefail
[ "$#" -lt 4 ] && { echo "usage: review-reply.sh <owner/repo> <pr> <comment_id> <body...>" >&2; exit 2; }
REPO="$1"; PR="$2"; CID="$3"; shift 3; BODY="$*"
case "$REPO" in
  *JUMO*) TOKFILE=/etc/hermes-discord-listener/jumo.token ;;
  *)      TOKFILE=/etc/hermes-discord-listener/hank.token ;;
esac
export GH_TOKEN; GH_TOKEN="$(cat "$TOKFILE")"
gh api -X POST "repos/$REPO/pulls/$PR/comments/$CID/replies" \
  -f body="$BODY" --jq '"REPLY-POSTED: " + .html_url'
