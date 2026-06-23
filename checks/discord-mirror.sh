#!/bin/bash
# Discord-Mirror: postet kompakte QA-Zusammenfassung in Discord-Channel
# Erwartet ENV-Variablen: DISCORD_WEBHOOK_URL, PR_NUMBER, REPO_FULL, HEAD_REF, BASE_REF,
#   STATUS_SECRETS, STATUS_DIFF, STATUS_LINT, STATUS_AEM_STATIC, STATUS_VISUAL,
#   STATUS_PATHS, STATUS_REVIEWS, STATUS_CODE_REVIEW
if [ -z "$DISCORD_WEBHOOK_URL" ]; then
  echo "No DISCORD_WEBHOOK_URL set - skipping Discord mirror"
  exit 0
fi

ICON_TO_EMOJI() {
  case "$1" in
    pass) echo "E_PASS" ;;
    fail) echo "E_FAIL" ;;
    warn) echo "E_WARN" ;;
    *)    echo "E_SKIP" ;;
  esac
}

EMOJI() {
  case "$1" in
    E_PASS) echo "✅" ;;
    E_FAIL) echo "❌" ;;
    E_WARN) echo "⚠️" ;;
    *) echo "⏭️" ;;
  esac
}

YL=$(EMOJI $(ICON_TO_EMOJI "${STATUS_SECRETS:-skip}"))
SC=$(EMOJI $(ICON_TO_EMOJI "${STATUS_DIFF:-skip}"))
LT=$(EMOJI $(ICON_TO_EMOJI "${STATUS_LINT:-skip}"))
AS=$(EMOJI $(ICON_TO_EMOJI "${STATUS_AEM_STATIC:-skip}"))
VS=$(EMOJI $(ICON_TO_EMOJI "${STATUS_VISUAL:-skip}"))
PA=$(EMOJI $(ICON_TO_EMOJI "${STATUS_PATHS:-skip}"))
RV=$(EMOJI $(ICON_TO_EMOJI "${STATUS_REVIEWS:-skip}"))
CR=$(EMOJI $(ICON_TO_EMOJI "${STATUS_CODE_REVIEW:-skip}"))

ALL_GREEN=true
for s in "$STATUS_SECRETS" "$STATUS_DIFF" "$STATUS_LINT" "$STATUS_PATHS" "$STATUS_REVIEWS" "$STATUS_CODE_REVIEW"; do
  if [ -n "$s" ] && [ "$s" != "pass" ] && [ "$s" != "skip" ]; then
    ALL_GREEN=false
  fi
done

if [ "$ALL_GREEN" = "true" ]; then
  HEADLINE="✅ **All checks green.**"
else
  HEADLINE="⚠️ **Action required** — see failed checks."
fi

SUMMARY="${HEADLINE}
${YL} secret-scan · ${SC} diff-size · ${LT} lint · ${AS} aem-static · ${VS} visual · ${PA} paths · ${RV} reviews · ${CR} code-review
PR #${PR_NUMBER} · \`${HEAD_REF}\` → \`${BASE_REF}\`"

PAYLOAD=$(jq -n --arg c "🤖 hermes-work QA Report — ${REPO_FULL}
${SUMMARY}
<https://github.com/${REPO_FULL}/pull/${PR_NUMBER}|View PR>" '{content: $c}')

curl -fsS -H "Content-Type: application/json" -d "$PAYLOAD" "$DISCORD_WEBHOOK_URL" || echo "Discord mirror failed (non-fatal)"