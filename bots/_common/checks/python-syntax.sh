#!/bin/bash
# Check-Modul: python-syntax — py_compile auf geänderten .py-Dateien. Env: DIFF_FILES. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'python-syntax','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
PY_FILES=$(echo "$DIFF_FILES" | grep -E '\.py$' || true)
[ -z "$PY_FILES" ] && { emit skip "Keine Python-Dateien im Diff"; exit 0; }
ERRS=0
for f in $PY_FILES; do
  [ -f "$f" ] && { python3 -m py_compile "$f" 2>/dev/null || ERRS=$((ERRS + 1)); }
done
if [ "$ERRS" -eq 0 ]; then
  emit pass "$(echo "$PY_FILES" | grep -c .) Python-Dateien kompilieren sauber"
else
  emit fail "Syntaxfehler in $ERRS Python-Datei(en)"
fi
