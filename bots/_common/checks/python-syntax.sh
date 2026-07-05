#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: python-syntax — py_compile auf geänderten .py-Dateien. Env: DIFF_FILES. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'python-syntax','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
mapfile -t PY_FILES < <(printf '%s\n' "$DIFF_FILES" | grep -E '\.py$' || true)
[ "${#PY_FILES[@]}" -eq 0 ] && { emit skip "$(t "Keine Python-Dateien im Diff" "No Python files in the diff")"; exit 0; }
ERRS=0; CHECKED=0
for f in "${PY_FILES[@]}"; do
  [ -f "$f" ] || continue   # gelöschte Dateien überspringen
  CHECKED=$((CHECKED + 1))
  python3 -m py_compile "$f" 2>/dev/null || ERRS=$((ERRS + 1))
done
[ "$CHECKED" -eq 0 ] && { emit skip "$(t "Nur gelöschte Python-Dateien im Diff" "Only deleted Python files in the diff")"; exit 0; }
if [ "$ERRS" -eq 0 ]; then
  emit pass "$(t "$CHECKED Python-Datei(en) kompilieren sauber" "$CHECKED Python file(s) compile cleanly")"
else
  emit fail "$(t "Syntaxfehler in $ERRS von $CHECKED Python-Datei(en)" "Syntax errors in $ERRS of $CHECKED Python file(s)")"
fi
