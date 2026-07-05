#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: ruff — schneller Python-Lint auf geänderten Dateien (fängt undefined
# names, unbenutzte Imports etc., die py_compile nie sieht). Env: DIFF_FILES. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'ruff','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
command -v ruff >/dev/null 2>&1 || { emit skip "$(t "ruff nicht installiert" "ruff not installed")"; exit 0; }
mapfile -t PY_FILES < <(printf '%s\n' "$DIFF_FILES" | grep -E '\.py$' || true)
EXISTING=()
for f in "${PY_FILES[@]}"; do [ -f "$f" ] && EXISTING+=("$f"); done
[ "${#EXISTING[@]}" -eq 0 ] && { emit skip "$(t "Keine Python-Dateien im Diff" "No Python files in the diff")"; exit 0; }
# Nur echte Fehler-Klassen (E9 Syntax, F undefined/unused) — kein Style-Rauschen
OUT=$(ruff check --quiet --select E9,F --no-cache "${EXISTING[@]}" 2>/dev/null)
if [ -z "$OUT" ]; then
  emit pass "$(t "${#EXISTING[@]} Python-Datei(en) — ruff sauber (E9/F)" "${#EXISTING[@]} Python file(s) — ruff clean (E9/F)")"
else
  emit fail "$(printf '%s\n' "$OUT" | grep -c .) ruff-Finding(s) (E9/F) in geänderten Dateien"
fi
