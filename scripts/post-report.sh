#!/bin/bash
# Postet QA-Report als PR-Kommentar via Node-Script.
# Status-Werte kommen als ENV-Variablen (STATUS_SECRETS, STATUS_DIFF, ...).
set -e
# GitHub-API-Call: braucht github-script-Kontext. Wir machen das manuell mit curl+token.
PR_NUM="$PR_NUMBER"
REPO="$REPO_FULL"
HEAD_REF="$HEAD_REF"
BASE_REF="$BASE_REF"

# Werte aus ENV lesen
YL="${STATUS_SECRETS:-skip}"
SC="${STATUS_DIFF:-skip}"
LT="${STATUS_LINT:-skip}"
PA="${STATUS_PATHS:-skip}"
RV="${STATUS_REVIEWS:-skip}"
CR="${STATUS_CODE_REVIEW:-skip}"

ICON() {
  case "$1" in
    pass) echo "PASS_OK";;
    fail) echo "FAIL_X";;
    warn) echo "WARN_BANG";;
    *)    echo "SKIP_ARR";;
  esac
}
EMOJI() {
  case "$1" in
    PASS_OK) echo "✅";;
    FAIL_X) echo "❌";;
    WARN_BANG) echo "⚠️";;
    *) echo "⏭️";;
  esac
}

YI=$(EMOJI $(ICON "$YL"))
SI=$(EMOJI $(ICON "$SC"))
LI=$(EMOJI $(ICON "$LT"))
PI=$(EMOJI $(ICON "$PA"))
RI=$(EMOJI $(ICON "$RV"))
CI=$(EMOJI $(ICON "$CR"))

ALL_GREEN=true
for s in "$YL" "$SC" "$LT" "$PA" "$RV" "$CR"; do
  if [ "$s" != "pass" ] && [ "$s" != "skip" ]; then
    ALL_GREEN=false
  fi
done

if [ "$ALL_GREEN" = "true" ]; then
  SUMMARY_LINE="✅ **All checks green.**"
else
  SUMMARY_LINE="⚠️ **Action required** - see failed checks."
fi

BODY=$(cat <<EOF
## 🤖 hermes-work QA Report

PR #${PR_NUM} · \`${HEAD_REF}\` → \`${BASE_REF}\`

| Status | Check | Result |
|--------|-------|--------|
| ${YI} | **Secret-Scan** | ${YL} |
| ${SI} | **Diff-Size** | ${SC} |
| ${LI} | **Lint** | ${LT} |
| ${PI} | **Path-Convention** | ${PA} |
| ${RI} | **Review-Coverage** | ${RV} |
| ${CI} | **Code-Review** | ${CR} |

${SUMMARY_LINE}

_[Posted by hermes-work-commons v1.0.6](https://github.com/SkyTechNerds/hermes-work-commons)_
EOF
)

# GitHub-API-Call mit Token
PAYLOAD=$(jq -n --arg body "$BODY" '{body: $body}')
RESPONSE=$(curl -fsS -X POST   -H "Authorization: token $GITHUB_TOKEN"   -H "Accept: application/vnd.github+json"   -H "Content-Type: application/json"   -d "$PAYLOAD"   "https://api.github.com/repos/${REPO}/issues/${PR_NUM}/comments" 2>&1)
echo "$RESPONSE" | head -3
