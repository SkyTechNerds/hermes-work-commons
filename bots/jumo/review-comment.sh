#!/bin/bash
# hermes-work — postet einen ZEILENGENAUEN Inline-Review-Kommentar auf einen JUMO-PR.
# Token + Head-Commit-SHA werden intern aufgelöst (der Agent muss nichts davon bauen).
# Usage: review-comment.sh <pr> <file> <line> <message...>
set -euo pipefail
if [ "$#" -lt 4 ]; then
  echo "usage: review-comment.sh <pr> <file> <line> <message...>" >&2
  exit 2
fi
PR="$1"; FILE="$2"; LINE="$3"; shift 3; MSG="$*"
export GH_TOKEN
GH_TOKEN="$(cat /opt/jumo-testing/.token)"
REPO="JUMO-GmbH-Co-KG/JUMO-Website-CMS"
SHA="$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha)"
gh api -X POST "repos/$REPO/pulls/$PR/comments" \
  -f body="$MSG" -f commit_id="$SHA" -f path="$FILE" -F line="$LINE" -f side=RIGHT \
  --jq '"INLINE-POSTED: " + .html_url'
