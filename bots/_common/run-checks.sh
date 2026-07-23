#!/bin/bash
# hermes-work — generischer Check-Runner (Phase-2-Step-2). Ersetzt die Monolith-test-pr.sh.
# Usage: run-checks.sh <owner/repo> <pr> <branch> [base=main] [mode=post|dry]
#   - klont/aktualisiert das Repo (eigener Workdir je Repo, flock gegen parallele Läufe)
#   - fetcht refs/pull/<pr>/head (funktioniert auch für Fork-PRs, kein Vertrauen in Branch-Namen)
#   - löst Profil auf (.codemole.yml -> Marker-Erkennung -> Default) via resolve-profile.py
#   - fährt die aktiven Module bots/_common/checks/<name>.sh (fehlt ein Modul -> still überspringen)
#   - filtert (disabled/allow) + ignore-Globs auf DIFF_FILES
#   - rendert mit Profil-Header (render-report.py); mode=post postet, mode=dry gibt nur aus
#
# Check-Modul-Vertrag: cwd=REPO_DIR, Env REPO/PR/BASE_SHA/HEAD_SHA/DIFF_FILES/DIFF_FILES_FILE/
#   REPO_DIR/GH_TOKEN; gibt GENAU EIN JSON {name,status,message} auf stdout.
#   Leerer/ungültiger Output oder Timeout (120s) -> warn-Eintrag im Report (nicht mehr still).
set -uo pipefail
COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=load-token.sh
source "$COMMON/load-token.sh"

REPO="$1"; PR="$2"; BRANCH="$3"; BASE="${4:-main}"; MODE="${5:-post}"

# --- Input-Validierung: alles hier landet in git-Refs/Pfaden ---------------
case "$REPO" in
  */*) : ;;
  *) echo "run-checks: ungültiges Repo '$REPO'" >&2; exit 2 ;;
esac
case "$REPO" in
  *[!A-Za-z0-9._/-]*|-*|*..*) echo "run-checks: ungültiges Repo '$REPO'" >&2; exit 2 ;;
esac
case "$PR" in
  ''|*[!0-9]*) echo "run-checks: ungültige PR-Nummer '$PR'" >&2; exit 2 ;;
esac
for ref in "$BRANCH" "$BASE"; do
  case "$ref" in
    ''|-*|*..*|*[!A-Za-z0-9._/-]*) echo "run-checks: ungültiger Ref-Name '$ref'" >&2; exit 2 ;;
  esac
done

SLUG="$(printf '%s' "$REPO" | tr '/' '-')"
export REPO_DIR="${REPO_DIR:-/opt/hermes-runner-workdir/$SLUG}"
mkdir -p "$(dirname "$REPO_DIR")"

# Nur ein Lauf pro Workdir (synchronize-Bursts / parallele PRs desselben Repos).
exec 9>"$REPO_DIR.lock"
flock -w 540 9 || { echo "run-checks: Lock-Timeout für $REPO_DIR" >&2; exit 1; }

# Token NICHT in Remote-URL/Argumente einbetten (landet sonst in .git/config + ps).
# Stattdessen pro git-Kommando als Basic-Auth-Header (wie actions/checkout).
GIT_AUTH="http.https://github.com/.extraheader=Authorization: basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
gitauth() { git -c "$GIT_AUTH" "$@"; }

if [ ! -d "$REPO_DIR/.git" ]; then
  gitauth clone --quiet "https://github.com/${REPO}.git" "$REPO_DIR" \
    || { echo "run-checks: Clone fehlgeschlagen für $REPO" >&2; exit 1; }
fi
cd "$REPO_DIR"
# Falls ein alter Checkout noch Credentials in der Remote-URL trägt: entfernen.
git remote set-url origin "https://github.com/${REPO}.git" 2>/dev/null || true

# PR-Head über refs/pull/<n>/head holen: funktioniert für Fork-PRs und macht den
# Branch-Namen sicherheitstechnisch irrelevant. Fetch-Fehler = harter Abbruch —
# sonst liefen die Checks still auf dem Stand des vorherigen PRs (Stale-Checkout).
# Retry: refs/pull/<n>/head propagiert bei GitHub oft erst ein paar Sekunden nach
# PR-Oeffnung. Ohne Retry brach der Lauf ab und postete nichts (PR #379). Backoff 3/6/9s.
FETCH_OK=""
for attempt in 1 2 3 4; do
  if gitauth fetch --quiet --force origin \
      "+refs/pull/$PR/head:refs/hermes/pr" "+refs/heads/$BASE:refs/hermes/base"; then
    FETCH_OK=1; break
  fi
  [ "$attempt" -lt 4 ] && { echo "run-checks: Fetch-Versuch $attempt fehlgeschlagen ($REPO#$PR) — refs/pull/$PR/head evtl. noch nicht propagiert, retry..." >&2; sleep $((attempt * 3)); }
done
[ -n "$FETCH_OK" ] || { echo "run-checks: Fetch fehlgeschlagen ($REPO#$PR) nach 4 Versuchen" >&2; exit 1; }
git checkout --quiet --force --detach refs/hermes/pr \
  || { echo "run-checks: Checkout fehlgeschlagen" >&2; exit 1; }
git clean -fdq 2>/dev/null || true   # stale untracked Dateien (z.B. alte .codemole.yml) entfernen

# merge-base statt origin/<base>: ist die Base seit dem Abzweig weitergelaufen,
# enthielte der Zwei-Punkt-Diff sonst die INVERSEN Base-Änderungen.
export HEAD_SHA="$(git rev-parse refs/hermes/pr)"
export BASE_SHA="$(git merge-base refs/hermes/base "$HEAD_SHA" 2>/dev/null || git rev-parse refs/hermes/base)"
export DIFF_FILES="$(git diff --name-only "$BASE_SHA" "$HEAD_SHA")"
[ -z "$DIFF_FILES" ] && { echo "EMPTY_DIFF" >&2; exit 0; }

# PR-Sprache erkennen (de/en) — steuert Report- und Check-Meldungen
export CODEMOLE_LANG="$(bash "$COMMON/detect-lang.sh" "$REPO" "$PR" 2>/dev/null || echo de)"

RESOLVE="$(python3 "$COMMON/resolve-profile.py" "$REPO_DIR" "$REPO" 2>/dev/null)"
PROFILE="$(printf '%s' "$RESOLVE" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("profile","generic"))' 2>/dev/null || echo generic)"
PSOURCE="$(printf '%s' "$RESOLVE" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("source","auto"))' 2>/dev/null || echo auto)"
CHECKS="$(printf '%s' "$RESOLVE" | python3 -c 'import sys,json;print(" ".join(json.load(sys.stdin).get("checks",[])))' 2>/dev/null)"
if [ "$CODEMOLE_LANG" = "en" ]; then
  if [ "$PSOURCE" = "auto" ]; then SRCTXT="auto-detected"; else SRCTXT="from \`$PSOURCE\`"; fi
  export CODEMOLE_PROFILE_LINE="Profile: \`$PROFILE\` · $SRCTXT · [⚙ Configurable](https://web.skycryer.com/codemole/docs/en/#config)"
else
  if [ "$PSOURCE" = "auto" ]; then SRCTXT="automatisch erkannt"; else SRCTXT="aus \`$PSOURCE\`"; fi
  export CODEMOLE_PROFILE_LINE="Profil: \`$PROFILE\` · $SRCTXT · [⚙ Konfigurierbar](https://web.skycryer.com/codemole/docs/#config)"
fi

# aem-eds (z.B. JUMO) hat einen eigenen Node-Runner run.js (9 Checks, zu komplex für Bash-Module).
# Delegieren: run.js löst Profil/Header selbst auf, fährt die Checks und postet (mode=post).
# Env (REPO/REPO_DIR/GH_TOKEN/GITHUB_TOKEN) ist gesetzt -> postet im App-Pfad als thecodemole[bot].
# (Das flock-fd 9 bleibt über exec erhalten -> der Lock gilt auch für run.js.)
if [ "$PROFILE" = "aem-eds" ]; then
  if [ ! -f "$COMMON/../jumo/run.js" ]; then
    echo "run-checks: Profil aem-eds, aber jumo/run.js fehlt — keine Checks gelaufen!" >&2
    exit 1
  fi
  [ "$MODE" = "dry" ] && export DRY_RUN=1
  exec node "$COMMON/../jumo/run.js" "$BRANCH" "$PR" "$BASE" collect
fi
export DIFF_FILES="$(printf '%s\n' "$DIFF_FILES" | RESOLVE="$RESOLVE" python3 "$COMMON/path-ignored.py")"
[ -z "$DIFF_FILES" ] && { echo "run-checks: alle geänderten Dateien per ignore ausgenommen" >&2; exit 0; }

# Gefilterte Datei-Liste als Datei für git --pathspec-from-file (ignore gilt
# damit auch für Content-Scans wie secret-scan/diff-size, nicht nur Datei-Checks).
DIFF_FILES_FILE="/tmp/runchecks-$SLUG-$PR.files"
printf '%s\n' "$DIFF_FILES" > "$DIFF_FILES_FILE"
export DIFF_FILES_FILE

export CM_INLINE="/tmp/cm-inline-$SLUG-$PR.jsonl"; : > "$CM_INLINE"
export REPO PR BASE_SHA HEAD_SHA DIFF_FILES GH_TOKEN GITHUB_TOKEN REPO_DIR RESOLVE CM_INLINE
RESULTS="/tmp/runchecks-$SLUG-$PR.json"
echo '{"checks":[' > "$RESULTS"; FIRST=1
for c in $CHECKS; do
  # Defensive Doppelung zur Allowlist in resolve-profile.py: nie Pfade zulassen.
  case "$c" in *[!a-z0-9_-]*|'') continue ;; esac
  MOD="$COMMON/checks/$c.sh"
  [ -f "$MOD" ] || continue
  OUT="$(timeout 120 bash "$MOD" 2>/dev/null)"
  # Vertrag erzwingen: genau ein gültiges JSON-Objekt — sonst würde EIN kaputtes
  # Modul das gesamte Results-JSON (und damit den Report) zerstören.
  OUT="$(printf '%s' "$OUT" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
    assert isinstance(d, dict) and d.get("name") and d.get("status")
    print(json.dumps(d))
except Exception:
    pass' 2>/dev/null)"
  [ -z "$OUT" ] && OUT="$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1],"status":"warn","message":"Check-Modul lieferte keinen gültigen Output (Fehler/Timeout)"}))' "$c")"
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
  python3 "$COMMON/post-comment.py" "$REPO" "$PR" "$OUT_MD"
  [ -s "$CM_INLINE" ] && python3 "$COMMON/post-inline-findings.py" "$CM_INLINE" "$REPO" "$PR"
elif [ -s "$CM_INLINE" ]; then
  echo "=== INLINE-FUNDE (dry) ==="; cat "$CM_INLINE"
fi
