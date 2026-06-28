#!/bin/bash
# Check-Modul: includes — verwaiste !include-Referenzen. Env: BASE_SHA, HEAD_SHA, REPO_DIR. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'includes','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
INCLUDE_REFS=$(git diff "$BASE_SHA" "$HEAD_SHA" \
  | grep -oE '![[:space:]]*include[[:space:]]+[^\n]*\.ya?ml' \
  | sed -E 's/^![[:space:]]*include[[:space:]]+//;s/^["\x27]//;s/["\x27]$//' \
  | sort -u || true)
if [ -z "$INCLUDE_REFS" ]; then emit skip "Keine include-Änderungen im Diff"; exit 0; fi
MISSING=""
for ref in $INCLUDE_REFS; do
  [ -f "$REPO_DIR/$ref" ] || MISSING="$MISSING $ref"
done
if [ -n "$MISSING" ]; then emit fail "Fehlende include-Dateien:$MISSING"; else emit pass "Alle include-Referenzen aufgelöst"; fi
