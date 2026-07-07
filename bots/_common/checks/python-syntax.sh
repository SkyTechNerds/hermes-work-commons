#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: python-syntax — py_compile auf geänderten .py-Dateien; zeigt den echten
# Syntaxfehler (datei:zeile: Message) im Report statt nur zu zählen. Env: DIFF_FILES. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'python-syntax','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
mapfile -t PY_FILES < <(printf '%s\n' "$DIFF_FILES" | grep -E '\.py$' || true)
[ "${#PY_FILES[@]}" -eq 0 ] && { emit skip "$(t "Keine Python-Dateien im Diff" "No Python files in the diff")"; exit 0; }
ERRS=0; CHECKED=0; DETAIL=""
for f in "${PY_FILES[@]}"; do
  [ -f "$f" ] || continue
  CHECKED=$((CHECKED + 1))
  ERR="$(python3 -m py_compile "$f" 2>&1)" && continue
  ERRS=$((ERRS + 1))
  LN="$(printf '%s' "$ERR" | grep -oE 'line [0-9]+' | head -1 | grep -oE '[0-9]+')"
  MSG="$(printf '%s' "$ERR" | grep -E 'Error' | tail -1 | sed 's/^[[:space:]]*//')"
  DETAIL="${DETAIL}
${f}:${LN:-1}: ${MSG:-SyntaxError}"
done
[ "$CHECKED" -eq 0 ] && { emit skip "$(t "Nur gelöschte Python-Dateien im Diff" "Only deleted Python files in the diff")"; exit 0; }
if [ "$ERRS" -eq 0 ]; then
  emit pass "$(t "$CHECKED Python-Datei(en) kompilieren sauber" "$CHECKED Python file(s) compile cleanly")"
else
  FULL="$(t "Syntaxfehler in $ERRS von $CHECKED Python-Datei(en):" "Syntax errors in $ERRS of $CHECKED Python file(s):")${DETAIL}"
  python3 -c "import json,sys;print(json.dumps({'name':'python-syntax','status':'fail','message':sys.argv[1]}))" "$FULL"
fi
