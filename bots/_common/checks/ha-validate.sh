#!/bin/bash
# Check-Modul: ha-validate — HA-Config-Validierung. Env: REPO_DIR. cwd=REPO_DIR.
# ⚠️ check_config IMPORTIERT custom_components/* aus dem PR-Checkout (= führt
# untrusted Python aus). Akzeptiertes Restrisiko für Team-Repos; für einen
# public Betrieb muss dieser Check in eine Sandbox (siehe Roadmap Self-Hosting).
emit() { python3 -c "import json,sys;print(json.dumps({'name':'ha-validate','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
command -v hass >/dev/null 2>&1 || { emit skip "hass-CLI nicht installiert"; exit 0; }
HASS_OUT=$(timeout 90 hass --script check_config -c "$REPO_DIR" 2>&1)
RC=$?
if [ "$RC" -eq 124 ]; then
  emit warn "HA-Validation Timeout (90s) — nicht bewertbar"
elif [ "$RC" -ne 0 ] || printf '%s' "$HASS_OUT" | grep -qiE "failed|invalid config|config error"; then
  emit fail "HA-Validation meldet Fehler (Exit $RC)"
else
  emit pass "HA-Config valide"
fi
