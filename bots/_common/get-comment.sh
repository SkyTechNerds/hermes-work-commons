#!/bin/bash
# hermes-work — liest einen Review-(Inline-)Kommentar + ggf. den Eltern-Kommentar
# (das urspruengliche Finding) fuer Kontext. Token intern. Usage: get-comment.sh <owner/repo> <comment_id>
set -uo pipefail
[ "$#" -lt 2 ] && { echo "usage: get-comment.sh <owner/repo> <comment_id>" >&2; exit 2; }
REPO="$1"; CID="$2"
case "$REPO" in
  *JUMO*) TOKFILE=/etc/hermes-discord-listener/jumo.token ;;
  *)      TOKFILE=/etc/hermes-discord-listener/hank.token ;;
esac
export GH_TOKEN; GH_TOKEN="$(cat "$TOKFILE")"
gh api "repos/$REPO/pulls/comments/$CID" \
  --jq '"FILE: \(.path):\(.line)\nAUTHOR: \(.user.login)\nIN_REPLY_TO: \(.in_reply_to_id // "-")\nBODY:\n\(.body)"'
PARENT=$(gh api "repos/$REPO/pulls/comments/$CID" --jq '.in_reply_to_id // empty' 2>/dev/null)
if [ -n "$PARENT" ]; then
  echo "--- urspruengliches Finding (#$PARENT) ---"
  gh api "repos/$REPO/pulls/comments/$PARENT" --jq '"AUTHOR: \(.user.login)\n\(.body)"'
fi
