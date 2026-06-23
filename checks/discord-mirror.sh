#!/bin/bash
# Discord-Mirror: postet kompakte QA-Zusammenfassung in Discord-Channel
if [ -z "$DISCORD_WEBHOOK_URL" ]; then
  echo "No DISCORD_WEBHOOK_URL set - skipping Discord mirror"
  exit 0
fi

ICON() {
  case "$1" in
    pass) echo "PASS_OK";;
    fail) echo "FAIL_X";;
    warn) echo "WARN_BANG";;
    *)    echo "SKIP_ARR";;
  esac
}

# Status pro Step aus den env-Variablen lesen
YL_RAW='${{ steps.secrets.outputs.status }}'
SC_RAW='${{ steps.diff.outputs.status }}'
LT_RAW='${{ steps.lint.outputs.status }}'
PA_RAW='${{ steps.paths.outputs.status }}'
RV_RAW='${{ steps.reviews.outputs.status }}'
CR_RAW='${{ steps.code-review.outputs.status }}'

YI=$(ICON "$YL_RAW")
SI=$(ICON "$SC_RAW")
LI=$(ICON "$LT_RAW")
PI=$(ICON "$PA_RAW")
RI=$(ICON "$RV_RAW")
CI=$(ICON "$CR_RAW")

# Mapping zurueck zu Emoji
EMOJI() {
  case "$1" in
    PASS_OK) echo "✅";;
    FAIL_X) echo "❌";;
    WARN_BANG) echo "⚠️";;
    *) echo "⏭️";;
  esac
}

YI=$(EMOJI "$YI")
SI=$(EMOJI "$SI")
LI=$(EMOJI "$LI")
PI=$(EMOJI "$PI")
RI=$(EMOJI "$RI")
CI=$(EMOJI "$CI")

PR_NUM='${{ github.event.pull_request.number }}'
REPO_NAME='${{ github.repository }}'

SUMMARY="**PR #${PR_NUM}** — ${YI} secret-scan · ${SI} diff-size · ${LI} lint · ${PI} paths · ${RI} reviews · ${CI} code-review"
PAYLOAD=$(jq -n --arg c "🤖 hermes-work QA Report\n${SUMMARY}\n<https://github.com/${REPO_NAME}/pull/${PR_NUM}|View PR>" '{content: $c}')

curl -fsS -H "Content-Type: application/json" -d "$PAYLOAD" "$DISCORD_WEBHOOK_URL"
