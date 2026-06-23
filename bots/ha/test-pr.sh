#!/bin/bash
# hermes-work -- HA-Config PR-Test Runner.
# Usage: test-pr.sh <branch> <pr> [base=main] [mode=collect]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_common/load-token.sh
source "$SCRIPT_DIR/../_common/load-token.sh"

PR="$1"
BRANCH="$2"
BASE="${3:-main}"
MODE="${4:-collect}"

export REPO="SkyTechNerds/homeassistant-config"
export REPO_DIR="${REPO_DIR:-/opt/ha-config-workdir}"

mkdir -p "$(dirname "$REPO_DIR")"
if [ ! -d "$REPO_DIR/.git" ]; then
  git clone --quiet "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git" "$REPO_DIR"
fi
cd "$REPO_DIR"
git fetch --quiet origin "$BRANCH" "$BASE"
git checkout --quiet "$BRANCH" 2>/dev/null || true

BASE_SHA=$(git rev-parse "origin/$BASE")
HEAD_SHA=$(git rev-parse HEAD)

DIFF_FILES=$(git diff --name-only "$BASE_SHA" "$HEAD_SHA")
if [ -z "$DIFF_FILES" ]; then
  echo "EMPTY_DIFF" >&2
  exit 0
fi

RESULTS_JSON=/tmp/ha-test-${PR}.json
echo '{"checks":[' > "$RESULTS_JSON"
FIRST=1

add_check() {
  local name="$1" status="$2" msg="$3"
  if [ "$FIRST" -eq 0 ]; then echo ',' >> "$RESULTS_JSON"; fi
  FIRST=0
  python3 -c "import json; print(json.dumps({'name':'$name','status':'$status','message':'$msg'}))" >> "$RESULTS_JSON"
}

# === Check 1: YAML-Lint ===
YAML_FILES=$(echo "$DIFF_FILES" | grep -E '\.(ya?ml)$' || true)
if [ -z "$YAML_FILES" ]; then
  add_check "yamllint" "skip" "Keine YAML-Dateien im Diff"
else
  YAML_ERR=$(yamllint -f parsable $YAML_FILES 2>&1 || true)
  if [ -z "$YAML_ERR" ]; then
    N=$(echo "$YAML_FILES" | wc -l)
    add_check "yamllint" "pass" "$N YAML-Dateien sauber"
  else
    N=$(echo "$YAML_ERR" | wc -l)
    add_check "yamllint" "fail" "$N Lint-Fehler in YAML"
    echo "$YAML_ERR" > /tmp/ha-yamllint-${PR}.txt
  fi
fi

# === Check 2: Secret-Scan ===
SECRET_HITS=$(git diff "$BASE_SHA" "$HEAD_SHA" \
  | grep -iE 'password[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{6,}|api_key[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{8,}|token[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{8,}' \
  | grep -vE '^[-+][[:space:]]*#|!secret' || true)
if [ -z "$SECRET_HITS" ]; then
  add_check "secret-scan" "pass" "Keine Klartext-Secrets im Diff"
else
  N=$(echo "$SECRET_HITS" | wc -l)
  add_check "secret-scan" "fail" "$N moegliche Klartext-Secrets"
  echo "$SECRET_HITS" > /tmp/ha-secrets-${PR}.txt
fi

# === Check 3: Diff-Stats ===
ADDED=$(git diff --numstat "$BASE_SHA" "$HEAD_SHA" | awk '{sum+=$1} END {print sum+0}')
REMOVED=$(git diff --numstat "$BASE_SHA" "$HEAD_SHA" | awk '{sum+=$2} END {print sum+0}')
FILE_COUNT=$(echo "$DIFF_FILES" | wc -l)
if [ "$ADDED" -gt 1000 ] || [ "$FILE_COUNT" -gt 30 ]; then
  add_check "diff-size" "warn" "Grosser Diff: +${ADDED}/-${REMOVED} in ${FILE_COUNT} Dateien"
else
  add_check "diff-size" "pass" "Diff +${ADDED}/-${REMOVED} in ${FILE_COUNT} Dateien"
fi

# === Check 4: HA-Validation ===
if command -v hass >/dev/null 2>&1; then
  HASS_OUT=$(timeout 90 hass --script check_config -c "$REPO_DIR" 2>&1 || true)
  if echo "$HASS_OUT" | grep -qiE "failed|invalid config|config error"; then
    add_check "ha-validate" "fail" "HA-Validation meldet Fehler"
    echo "$HASS_OUT" > /tmp/ha-hass-${PR}.txt
  else
    add_check "ha-validate" "pass" "HA-Config valide"
  fi
else
  add_check "ha-validate" "skip" "hass-CLI nicht installiert"
fi

# === Check 5: Verwaiste !include ===
INCLUDE_REFS=$(git diff "$BASE_SHA" "$HEAD_SHA" \
  | grep -oE '![[:space:]]*include[[:space:]]+[^\n]*\.ya?ml' \
  | sed -E 's/^![[:space:]]*include[[:space:]]+//;s/^["\x27]//;s/["\x27]$//' \
  | sort -u || true)
if [ -n "$INCLUDE_REFS" ]; then
  MISSING=""
  for ref in $INCLUDE_REFS; do
    if [ ! -f "$REPO_DIR/$ref" ]; then MISSING="$MISSING $ref"; fi
  done
  if [ -n "$MISSING" ]; then
    add_check "includes" "fail" "Fehlende include-Dateien:$MISSING"
  else
    add_check "includes" "pass" "Alle include-Referenzen aufloesbar"
  fi
else
  add_check "includes" "skip" "Keine include-Aenderungen im Diff"
fi

echo ']}' >> "$RESULTS_JSON"

python3 /opt/ha-testing/render-report.py "$RESULTS_JSON" "$PR" "$BRANCH" "$BASE"
python3 /opt/ha-testing/post-comment.py "$PR" /tmp/ha-report-${PR}.md
