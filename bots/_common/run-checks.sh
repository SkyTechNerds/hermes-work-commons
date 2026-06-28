#!/bin/bash
# hermes-work — generischer Check-Runner (Phase-2-Step-2). Ersetzt schrittweise die Monolith-test-pr.sh.
# Usage: run-checks.sh <owner/repo> <pr> <branch> [base=main] [mode=post|dry]
#   - klont/aktualisiert das Repo (eigener Workdir je Repo)
#   - löst Profil auf (.codemole.yml -> Marker-Erkennung -> Default) via resolve-profile.py
#   - fährt die aktiven Module bots/_common/checks/<name>.sh (fehlt ein Modul -> still überspringen)
#   - filtert (disabled/allow) + ignore-Globs auf DIFF_FILES
#   - rendert mit Profil-Header (render-report.py); mode=post postet, mode=dry gibt nur aus
#
# Check-Modul-Vertrag: cwd=REPO_DIR, Env REPO/PR/BASE_SHA/HEAD_SHA/DIFF_FILES/REPO_DIR/GH_TOKEN;
#   gibt GENAU EIN JSON {name,status,message} auf stdout (leer = still übersprungen).
set -uo pipefail
COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=load-token.sh
source "$COMMON/load-token.sh"

REPO="$1"; PR="$2"; BRANCH="$3"; BASE="${4:-main}"; MODE="${5:-post}"
SLUG="$(printf '%s' "$REPO" | tr '/' '-')"
export REPO_DIR="${REPO_DIR:-/opt/hermes-runner-workdir/$SLUG}"
mkdir -p "$(dirname "$REPO_DIR")"
[ -d "$REPO_DIR/.git" ] || git clone --quiet "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git" "$REPO_DIR"
cd "$REPO_DIR"
git fetch --quiet origin "$BRANCH" "$BASE" 2>/dev/null
git checkout --quiet "$BRANCH" 2>/dev/null || true
git reset --quiet --hard "origin/$BRANCH" 2>/dev/null || true
git clean -fdq 2>/dev/null || true   # stale untracked Dateien (z.B. alte .codemole.yml) entfernen -> pristiner Checkout

export BASE_SHA="$(git rev-parse "origin/$BASE")"
export HEAD_SHA="$(git rev-parse HEAD)"
export DIFF_FILES="$(git diff --name-only "$BASE_SHA" "$HEAD_SHA")"
[ -z "$DIFF_FILES" ] && { echo "EMPTY_DIFF" >&2; exit 0; }

RESOLVE="$(python3 "$COMMON/resolve-profile.py" "$REPO_DIR" "$REPO" 2>/dev/null)"
PROFILE="$(printf '%s' "$RESOLVE" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("profile","generic"))' 2>/dev/null || echo generic)"
PSOURCE="$(printf '%s' "$RESOLVE" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("source","auto"))' 2>/dev/null || echo auto)"
CHECKS="$(printf '%s' "$RESOLVE" | python3 -c 'import sys,json;print(" ".join(json.load(sys.stdin).get("checks",[])))' 2>/dev/null)"
if [ "$PSOURCE" = "auto" ]; then SRCTXT="automatisch erkannt"; else SRCTXT="aus \`$PSOURCE\`"; fi
export CODEMOLE_PROFILE_LINE="Profil: \`$PROFILE\` · $SRCTXT · [⚙ Konfigurierbar](https://web.skycryer.com/codemole/docs/#config)"
export DIFF_FILES="$(printf '%s\n' "$DIFF_FILES" | RESOLVE="$RESOLVE" python3 "$COMMON/path-ignored.py")"

export REPO PR BASE_SHA HEAD_SHA DIFF_FILES GH_TOKEN GITHUB_TOKEN REPO_DIR
RESULTS="/tmp/runchecks-$SLUG-$PR.json"
echo '{"checks":[' > "$RESULTS"; FIRST=1
for c in $CHECKS; do
  MOD="$COMMON/checks/$c.sh"
  [ -f "$MOD" ] || continue
  OUT="$(bash "$MOD" 2>/dev/null)"
  [ -z "$OUT" ] && continue
  [ "$FIRST" -eq 0 ] && echo ',' >> "$RESULTS"; FIRST=0
  printf '%s\n' "$OUT" >> "$RESULTS"
done
echo ']}' >> "$RESULTS"

# disabled/allow-Filter
RESOLVE="$RESOLVE" python3 - "$RESULTS" <<'PYEOF'
import json, os, sys
f = sys.argv[1]; r = json.loads(os.environ.get("RESOLVE", "{}"))
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
PYEOF

OUT_MD="/tmp/runchecks-$SLUG-$PR.md"
python3 "$COMMON/render-report.py" "$RESULTS" "$BRANCH" "$BASE" "$OUT_MD"
if [ "$MODE" = "post" ]; then
  python3 /opt/ha-testing/post-comment.py "$PR" "$OUT_MD"
fi
