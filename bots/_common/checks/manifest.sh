#!/bin/bash
# Check-Modul: manifest — HA-Custom-Component manifest.json Pflichtfelder. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'manifest','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
MAN=$(find custom_components -maxdepth 2 -name manifest.json 2>/dev/null | head -1)
[ -z "$MAN" ] && { emit fail "manifest.json fehlt komplett"; exit 0; }
MISSING=""
for field in domain name version documentation issue_tracker codeowners requirements iot_class; do
  jq -e ".${field}" "$MAN" >/dev/null 2>&1 || MISSING="${MISSING} ${field}"
done
if [ -z "$MISSING" ]; then
  emit pass "manifest.json hat alle Pflichtfelder"
else
  emit fail "manifest.json fehlt:${MISSING}"
fi
