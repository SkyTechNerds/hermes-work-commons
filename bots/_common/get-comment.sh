#!/bin/bash
# hermes-work — liest einen Review-(Inline-)Kommentar + ggf. den Eltern-Kommentar
# (das ursprüngliche Finding) für Kontext. Token intern. Usage: get-comment.sh <owner/repo> <comment_id>
set -uo pipefail
[ "$#" -lt 2 ] && { echo "usage: get-comment.sh <owner/repo> <comment_id>" >&2; exit 2; }
REPO="$1"; CID="$2"
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
JSON="$(gh api "repos/$REPO/pulls/comments/$CID")" || exit 1
COMMENT_JSON="$JSON" python3 <<'PY'
import os, json
c = json.loads(os.environ["COMMENT_JSON"])
user = (c.get("user") or {}).get("login", "")
print("FILE: %s:%s" % (c.get("path"), c.get("line")))
print("AUTHOR: %s" % user)
print("IN_REPLY_TO: %s" % (c.get("in_reply_to_id") or "-"))
print("BODY:")
print(c.get("body") or "")
PY
PARENT_ID="$(printf '%s' "$JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("in_reply_to_id") or "")')"
if [ -n "$PARENT_ID" ]; then
  echo "--- ursprüngliches Finding (#$PARENT_ID) ---"
  gh api "repos/$REPO/pulls/comments/$PARENT_ID" --jq '"AUTHOR: \(.user.login)\n\(.body)"'
fi
