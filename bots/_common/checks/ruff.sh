#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: ruff — Python-Lint (E9 Syntax, F undefined/unused) auf geänderten Dateien.
# ZWEI-PASS: meldet nur Funde, die gegenüber der Base NEU sind (ein Import wird oft erst
# durch eine Änderung anderswo "unused" → line-scoping wäre falsch, Base-Vergleich ist richtig).
# concise-Format = ein Fund pro Zeile (korrekter Zähler + auflistbar im Report).
# Env: DIFF_FILES, BASE_SHA. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'ruff','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
command -v ruff >/dev/null 2>&1 || { emit skip "$(t "ruff nicht installiert" "ruff not installed")"; exit 0; }
mapfile -t PY_FILES < <(printf '%s\n' "$DIFF_FILES" | grep -E '\.py$' || true)
EXISTING=()
for f in "${PY_FILES[@]}"; do [ -f "$f" ] && EXISTING+=("$f"); done
[ "${#EXISTING[@]}" -eq 0 ] && { emit skip "$(t "Keine Python-Dateien im Diff" "No Python files in the diff")"; exit 0; }

run_ruff() { ruff check --quiet --output-format concise --select E9,F --no-cache "$@" 2>/dev/null; }

BRANCH_OUT="$(run_ruff "${EXISTING[@]}")"

# Base-Pass: nur NEUE Funde melden (Vorbestand-Debt ignorieren)
NEW="$BRANCH_OUT"
if [ -n "${BASE_SHA:-}" ]; then
  CUR="$(git rev-parse HEAD 2>/dev/null)"
  if git checkout -q "$BASE_SHA" 2>/dev/null; then
    BASE_FILES=()
    for f in "${EXISTING[@]}"; do [ -f "$f" ] && BASE_FILES+=("$f"); done
    BASE_OUT=""
    [ "${#BASE_FILES[@]}" -gt 0 ] && BASE_OUT="$(run_ruff "${BASE_FILES[@]}")"
    git checkout -q "$CUR" 2>/dev/null
    NEW="$(BR="$BRANCH_OUT" BS="$BASE_OUT" python3 -c '
import os, re
def norm(l):  # Zeilen-/Spaltennummern raus (verschieben sich zwischen Base/Branch)
    return re.sub(r"^([^:]+):\d+:\d+: ", r"\1: ", l)
base = set(norm(l) for l in os.environ["BS"].splitlines() if l.strip())
for l in os.environ["BR"].splitlines():
    if l.strip() and norm(l) not in base:
        print(l)
')"
  fi
fi

if [ -z "$NEW" ]; then
  emit pass "$(t "${#EXISTING[@]} Python-Datei(en) — ruff sauber (E9/F)" "${#EXISTING[@]} Python file(s) — ruff clean (E9/F)")"
else
  N=$(printf '%s\n' "$NEW" | grep -c .)
  MSG="$(t "$N neue(r) ruff-Finding(s) (E9/F):" "$N new ruff finding(s) (E9/F):")
$NEW"
  python3 -c "import json,sys;print(json.dumps({'name':'ruff','status':'fail','message':sys.argv[1]}))" "$MSG"
fi
