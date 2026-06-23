#!/bin/bash
# Postet QA-Report als PR-Kommentar via GitHub-API.
# Status-Werte kommen als ENV-Variablen (STATUS_*).
set -e

PR_NUM="$PR_NUMBER"
REPO="$REPO_FULL"
HEAD_REF="$HEAD_REF"
BASE_REF="$BASE_REF"

YL="${STATUS_SECRETS:-skip}"
SC="${STATUS_DIFF:-skip}"
LT="${STATUS_LINT:-skip}"
AS="${STATUS_AEM_STATIC:-skip}"
VS="${STATUS_VISUAL:-skip}"
PA="${STATUS_PATHS:-skip}"
RV="${STATUS_REVIEWS:-skip}"
CR="${STATUS_CODE_REVIEW:-skip}"

ICON() {
  case "$1" in
    pass) echo "PASS_OK" ;;
    fail) echo "FAIL_X" ;;
    warn) echo "WARN_BANG" ;;
    *)    echo "SKIP_ARR" ;;
  esac
}

EMOJI() {
  case "$1" in
    PASS_OK) echo "✅" ;;
    FAIL_X) echo "❌" ;;
    WARN_BANG) echo "⚠️" ;;
    *) echo "⏭️" ;;
  esac
}

YI=$(EMOJI $(ICON "$YL"))
SI=$(EMOJI $(ICON "$SC"))
LI=$(EMOJI $(ICON "$LT"))
AI=$(EMOJI $(ICON "$AS"))
VI=$(EMOJI $(ICON "$VS"))
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
  SUMMARY_LINE="⚠️ **Action required** — see failed checks."
fi

BODY=$(cat <<EOF
## 🤖 hermes-work QA Report

PR #${PR_NUM} · \`${HEAD_REF}\` → \`${BASE_REF}\`

| ${YI} | **Secret-Scan** | ${YL} |
| ${SI} | **Diff-Size** | ${SC} |
| ${LI} | **Lint** | ${LT} |
| ${AI} | **AEM-Static-Scans** | ${AS} |
| ${VI} | **Visual-Snapshot** | ${VS} |
| ${PI} | **Path-Convention** | ${PA} |
| ${RI} | **Review-Coverage** | ${RV} |
| ${CI} | **Code-Review** | ${CR} |

${SUMMARY_LINE}

_[Posted by hermes-work-commons v2](https://github.com/SkyTechNerds/hermes-work-commons)_
EOF
)

PAYLOAD=$(jq -n --arg body "$BODY" '{body: $body}')
RESPONSE=$(curl -fsS -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "https://api.github.com/repos/${REPO}/issues/${PR_NUM}/comments" 2>&1) || {
  echo "::error::PR-Comment posten fehlgeschlagen: $RESPONSE"
  exit 0
}
echo "$RESPONSE" | head -3