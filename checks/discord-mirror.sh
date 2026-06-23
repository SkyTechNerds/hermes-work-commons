#!/bin/bash
# Discord-Mirror: postet kompakte QA-Zusammenfassung in Discord-Channel
if [ -z "$DISCORD_WEBHOOK_URL" ]; then
  echo "No DISCORD_WEBHOOK_URL set - skipping Discord mirror"
  exit 0
fi

ICON_TO_EMOJI() {
  case "$1" in
    pass) echo "E_PASS";;
    fail) echo "E_FAIL";;
    warn) echo "E_WARN";;
    *)    echo "E_SKIP";;
  esac
}

EMOJI() {
  case "$1" in
    E_PASS) echo "✅";;
    E_FAIL) echo "❌";;
    E_WARN) echo "⚠️";;
    *) echo "⏭️";;
  esac
}

YL=$(EMOJI $(ICON_TO_EMOJI '${{ steps.secrets.outputs.status }}'))
SC=$(EMOJI $(ICON_TO_EMOJI '${{ steps.diff.outputs.status }}'))
LT=$(EMOJI $(ICON_TO_EMOJI '${{ steps.lint.outputs.status }}'))
PA=$(EMOJI $(ICON_TO_EMOJI '${{ steps.paths.outputs.status }}'))
RV=$(EMOJI $(ICON_TO_EMOJI '${{ steps.reviews.outputs.status }}'))
CR=$(EMOJI $(ICON_TO_EMOJI '${{ steps.code-review.outputs.status }}'))

PR_NUM='${{ github.event.pull_request.number }}'
REPO_NAME='${{ github.repository }}'

SUMMARY="**PR #${PR_NUM}** — ${YL} secret-scan · ${SC} diff-size · ${LT} lint · ${PA} paths · ${RV} reviews · ${CR} code-review"
PAYLOAD=$(jq -n --arg c "🤖 hermes-work QA Report\n${SUMMARY}\n<https://github.com/${REPO_NAME}/pull/${PR_NUM}|View PR>" '{content: $c}')

curl -fsS -H "Content-Type: application/json" -d "$PAYLOAD" "$DISCORD_WEBHOOK_URL"
