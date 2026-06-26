#!/bin/bash
# hermes-work -- HA-Custom-Component PR-Test Runner für ha-soft-presence.
# Usage: test-pr.sh <pr> <branch> [base=main] [mode=collect]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_common/load-token.sh"

PR="$1"
BRANCH="$2"
BASE="${3:-main}"
MODE="${4:-collect}"

export REPO="SkyTechNerds/ha-soft-presence"
export REPO_DIR="${REPO_DIR:-/opt/ha-soft-presence-workdir}"

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

# --- Profil-Resolver (.codemole.yml -> Marker-Erkennung -> Default) ---
RESOLVE="$(python3 "$SCRIPT_DIR/../_common/resolve-profile.py" "$REPO_DIR" "$REPO" 2>/dev/null)"
PROFILE="$(printf '%s' "$RESOLVE" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("profile","ha-component"))' 2>/dev/null || echo ha-component)"
PSOURCE="$(printf '%s' "$RESOLVE" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("source","auto"))' 2>/dev/null || echo auto)"
if [ "$PSOURCE" = "auto" ]; then SRCTXT="automatisch erkannt"; else SRCTXT="aus \`$PSOURCE\`"; fi
export CODEMOLE_PROFILE_LINE="Profil: \`$PROFILE\` · $SRCTXT · [⚙ Konfigurierbar](https://web.skycryer.com/codemole/docs/#config)"

# ignore-Globs auf die Datei-Liste anwenden (Datei-basierte Checks: yamllint, includes)
DIFF_FILES="$(printf '%s\n' "$DIFF_FILES" | RESOLVE="$RESOLVE" python3 "$SCRIPT_DIR/../_common/path-ignored.py")"

RESULTS_JSON=/tmp/ha-soft-presence-test-${PR}.json
echo '{"checks":[' > "$RESULTS_JSON"
FIRST=1

add_check() {
  local name="$1" status="$2" msg="$3"
  if [ "$FIRST" -eq 0 ]; then echo ',' >> "$RESULTS_JSON"; fi
  FIRST=0
  python3 -c "import json; print(json.dumps({'name':'$name','status':'$status','message':'$msg'}))" >> "$RESULTS_JSON"
}

# === Check 1: Python Syntax (py_compile) ===
PY_FILES=$(echo "$DIFF_FILES" | grep -E '\.py$' || true)
if [ -z "$PY_FILES" ]; then
  add_check "python-syntax" "skip" "Keine Python-Dateien im Diff"
else
  SYNTAX_ERR=""
  for f in $PY_FILES; do
    if [ -f "$f" ]; then
      ERR=$(python3 -m py_compile "$f" 2>&1) || SYNTAX_ERR="${SYNTAX_ERR}\n${f}: ${ERR}"
    fi
  done
  if [ -z "$SYNTAX_ERR" ]; then
    N=$(echo "$PY_FILES" | wc -l)
    add_check "python-syntax" "pass" "$N Python-Dateien kompilieren sauber"
  else
    add_check "python-syntax" "fail" "Syntaxfehler in Python-Dateien"
    echo -e "$SYNTAX_ERR" > /tmp/ha-soft-presence-py-${PR}.txt
  fi
fi

# === Check 2: manifest.json Schema ===
if [ -f "custom_components/ha_soft_presence/manifest.json" ]; then
  REQUIRED_FIELDS="domain name version documentation issue_tracker codeowners requirements iot_class"
  MISSING=""
  for field in $REQUIRED_FIELDS; do
    if ! jq -e ".${field}" custom_components/ha_soft_presence/manifest.json >/dev/null 2>&1; then
      MISSING="${MISSING} ${field}"
    fi
  done
  if [ -z "$MISSING" ]; then
    add_check "manifest" "pass" "manifest.json hat alle Pflichtfelder"
  else
    add_check "manifest" "fail" "manifest.json fehlt:${MISSING}"
  fi
else
  add_check "manifest" "fail" "manifest.json fehlt komplett"
fi

# === Check 3: HACS-Konform (hacs.json) ===
if [ -f "hacs.json" ]; then
  if jq -e '.name' hacs.json >/dev/null 2>&1; then
    add_check "hacs" "pass" "hacs.json vorhanden + name-Feld gesetzt"
  else
    add_check "hacs" "warn" "hacs.json ohne name-Feld"
  fi
else
  add_check "hacs" "warn" "hacs.json fehlt (HACS-Listing problematisch)"
fi

# === Check 4: Uebersetzungen (translations/) ===
if [ -d "custom_components/ha_soft_presence/translations" ]; then
  LANG_FILES=$(find custom_components/ha_soft_presence/translations -name '*.json' 2>/dev/null | wc -l)
  EN_FILE="custom_components/ha_soft_presence/translations/en.json"
  if [ -f "$EN_FILE" ]; then
    EN_KEYS=$(jq -r '[.. | objects | keys[]] | unique | length' "$EN_FILE" 2>/dev/null || echo 0)
    MISMATCH=""
    for lang_file in custom_components/ha_soft_presence/translations/*.json; do
      [ "$lang_file" = "$EN_FILE" ] && continue
      LANG_KEYS=$(jq -r '[.. | objects | keys[]] | unique | length' "$lang_file" 2>/dev/null || echo 0)
      if [ "$LANG_KEYS" -ne "$EN_KEYS" ]; then
        LANG_NAME=$(basename "$lang_file" .json)
        MISMATCH="${MISMATCH} ${LANG_NAME}(${LANG_KEYS} vs ${EN_KEYS})"
      fi
    done
    if [ -z "$MISMATCH" ]; then
      add_check "translations" "pass" "${LANG_FILES} Sprachen, alle mit ${EN_KEYS} Keys konsistent"
    else
      add_check "translations" "warn" "Translations-Key-Mismatch:${MISMATCH}"
    fi
  else
    add_check "translations" "warn" "en.json fehlt - keine Pflicht-Sprache"
  fi
else
  add_check "translations" "skip" "Kein translations/-Verzeichnis"
fi

# === Check 5: Secret-Scan ===
SECRET_HITS=$(git diff "$BASE_SHA" "$HEAD_SHA" \
  | grep -iE 'password[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{6,}|api_key[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{8,}|token[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{8,}' \
  | grep -vE '^[-+][[:space:]]*#|!secret' || true)
if [ -z "$SECRET_HITS" ]; then
  add_check "secret-scan" "pass" "Keine Klartext-Secrets im Diff"
else
  N=$(echo "$SECRET_HITS" | wc -l)
  add_check "secret-scan" "fail" "$N mögliche Klartext-Secrets"
  echo "$SECRET_HITS" > /tmp/ha-soft-presence-secrets-${PR}.txt
fi

# === Check 6: Diff-Stats ===
ADDED=$(git diff --numstat "$BASE_SHA" "$HEAD_SHA" | awk '{sum+=$1} END {print sum+0}')
REMOVED=$(git diff --numstat "$BASE_SHA" "$HEAD_SHA" | awk '{sum+=$2} END {print sum+0}')
FILE_COUNT=$(echo "$DIFF_FILES" | wc -l)
if [ "$ADDED" -gt 1500 ] || [ "$FILE_COUNT" -gt 40 ]; then
  add_check "diff-size" "warn" "Grosser Diff: +${ADDED}/-${REMOVED} in ${FILE_COUNT} Dateien"
else
  add_check "diff-size" "pass" "Diff +${ADDED}/-${REMOVED} in ${FILE_COUNT} Dateien"
fi

echo ']}' >> "$RESULTS_JSON"

# Checks filtern: explizit Disabled raus; bei explizitem `checks:` nur diese (Allowlist).
if [ -n "$RESOLVE" ]; then
  RESOLVE="$RESOLVE" python3 - "$RESULTS_JSON" <<'PY'
import json, os, sys
f = sys.argv[1]; r = json.loads(os.environ["RESOLVE"])
disabled = set(r.get("disabled") or []); allow = set(r.get("allow") or [])
d = json.load(open(f, encoding="utf-8"))
def keep(c):
    n = c.get("name")
    if n in disabled:
        return False
    if allow and n not in allow:
        return False
    return True
d["checks"] = [c for c in d.get("checks", []) if keep(c)]
json.dump(d, open(f, "w", encoding="utf-8"))
PY
fi

# === Report generieren ===
python3 "$SCRIPT_DIR/../_common/render-report.py" "$RESULTS_JSON" "$BRANCH" "$BASE" /tmp/ha-soft-presence-report-${PR}.md

# === PR-Kommentar posten ===
COMMENT_BODY=$(jq -Rs '{body: .}' < /tmp/ha-soft-presence-report-${PR}.md)
echo "$COMMENT_BODY" | gh api -X POST "repos/${REPO}/issues/${PR}/comments" --input - 2>&1 | head -3
