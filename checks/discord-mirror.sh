#!/bin/bash
# Discord-Mirror: postet kompakte Zusammenfassung in Discord-Channel
if [ -z "$DISCORD_WEBHOOK_URL" ]; then
  echo "No DISCORD_WEBHOOK_URL set - skipping"
  exit 0
fi
YL='${{ steps.secrets.outputs.status }}'
# ... (analog zu HA-Workflow)
SUMMARY="**PR #${{ github.event.pull_request.number }}** — QA Report: $(cat /tmp/hermes-summary.txt 2>/dev/null || echo 'pending')"
PAYLOAD=$(jq -n --arg c "🤖 hermes-work QA\n${SUMMARY}\n<https://github.com/${{ github.repository }}/pull/${{ github.event.pull_request.number }}|View PR>" '{content: $c}')
curl -fsS -H "Content-Type: application/json" -d "$PAYLOAD" "$DISCORD_WEBHOOD_URL"
