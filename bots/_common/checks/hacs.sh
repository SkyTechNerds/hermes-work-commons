#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: hacs — hacs.json fürs HACS-Listing (Parse + name-Feld). cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'hacs','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
if [ -f hacs.json ]; then
  if ! jq -e . hacs.json >/dev/null 2>&1; then
    emit fail "$(t "hacs.json ist kein gültiges JSON" "hacs.json is not valid JSON")"
  elif jq -e '.name' hacs.json >/dev/null 2>&1; then
    emit pass "$(t "hacs.json vorhanden + name-Feld gesetzt" "hacs.json present + name field set")"
  else
    emit warn "$(t "hacs.json ohne name-Feld" "hacs.json missing the name field")"
  fi
else
  emit warn "$(t "hacs.json fehlt (HACS-Listing problematisch)" "hacs.json missing (problematic for HACS listing)")"
fi
