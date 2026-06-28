#!/bin/bash
# Check-Modul: ha-validate — HA-Config-Validierung. Env: REPO_DIR. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'ha-validate','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
if command -v hass >/dev/null 2>&1; then
  HASS_OUT=$(timeout 90 hass --script check_config -c "$REPO_DIR" 2>&1 || true)
  if echo "$HASS_OUT" | grep -qiE "failed|invalid config|config error"; then
    emit fail "HA-Validation meldet Fehler"
  else
    emit pass "HA-Config valide"
  fi
else
  emit skip "hass-CLI nicht installiert"
fi
