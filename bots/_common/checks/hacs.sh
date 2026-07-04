#!/bin/bash
# Check-Modul: hacs — hacs.json fürs HACS-Listing (Parse + name-Feld). cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'hacs','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
if [ -f hacs.json ]; then
  if ! jq -e . hacs.json >/dev/null 2>&1; then
    emit fail "hacs.json ist kein gültiges JSON"
  elif jq -e '.name' hacs.json >/dev/null 2>&1; then
    emit pass "hacs.json vorhanden + name-Feld gesetzt"
  else
    emit warn "hacs.json ohne name-Feld"
  fi
else
  emit warn "hacs.json fehlt (HACS-Listing problematisch)"
fi
