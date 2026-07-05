#!/bin/bash
# Check-Modul: ha-validate — HA-Config-Validierung, ZWEI-PASS (Base vs Branch).
# check_config auf einem nackten Checkout meldet immer Umgebungs-Bestandsfehler
# (Unknown device = .storage fehlt, fehlende Systemlibs, Alt-Configs). Deshalb wird
# gegen die Base-Baseline verglichen und nur NEUE Fehler gemeldet (Baseline pro
# BASE_SHA gecacht). Nutzt bevorzugt das aktuelle HA-venv (/opt/ha-venv, 2026.x).
# Env: REPO_DIR, BASE_SHA, HEAD_SHA. cwd=REPO_DIR.
# ⚠️ check_config IMPORTIERT custom_components/* aus dem PR-Checkout (untrusted
# Python). Akzeptiertes Restrisiko für Team-Repos; public -> Sandbox (Roadmap).
emit() { python3 -c "import json,sys;print(json.dumps({'name':'ha-validate','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }

HASS_BIN="${HASS_BIN:-}"
[ -z "$HASS_BIN" ] && [ -x /opt/ha-venv/bin/hass ] && HASS_BIN=/opt/ha-venv/bin/hass
[ -z "$HASS_BIN" ] && HASS_BIN="$(command -v hass || true)"
[ -z "$HASS_BIN" ] && { emit skip "hass-CLI nicht installiert"; exit 0; }
VER=$("$HASS_BIN" --version 2>/dev/null)

# check_config-Lauf -> normalisierte Fehlerzeilen (ANSI raus, nur Fehler, dedupe)
run_check() {  # $1 = Zielverzeichnis
  timeout 120 "$HASS_BIN" --script check_config -c "$1" 2>&1 | python3 -c '
import re, sys
txt = re.sub(r"\x1b\[[0-9;]*m", "", sys.stdin.read())
seen = set()
for ln in txt.splitlines():
    l = ln.strip()
    if re.search(r"(?i)^(error|failed)|invalid config|configuration error|error while", l):
        l = l.replace("`", "´")[:200]
        if l not in seen:
            seen.add(l); print(l)
'
}

# 1) Branch-Lauf (Workdir steht auf HEAD)
BRANCH_ERRS="$(run_check "$REPO_DIR")"

# 2) Baseline (Cache pro BASE_SHA; sonst BASE auschecken, laufen, zurück)
CACHE="/tmp/ha-validate-baseline-${BASE_SHA:-none}.txt"
if [ -n "${BASE_SHA:-}" ] && [ ! -f "$CACHE" ]; then
  CUR="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)"
  if git -C "$REPO_DIR" checkout -q "$BASE_SHA" 2>/dev/null; then
    run_check "$REPO_DIR" > "$CACHE" || true
    git -C "$REPO_DIR" checkout -q "$CUR" 2>/dev/null
  fi
fi
BASE_ERRS=""; [ -f "$CACHE" ] && BASE_ERRS="$(cat "$CACHE")"

# 3) Nur NEUE Fehler melden
NEW="$(BRANCH_ERRS="$BRANCH_ERRS" BASE_ERRS="$BASE_ERRS" python3 -c '
import os
base = set(os.environ["BASE_ERRS"].splitlines())
out = [l for l in os.environ["BRANCH_ERRS"].splitlines() if l and l not in base]
print("\n".join(out[:12]))
')"

BASE_N=$(printf '%s' "$BASE_ERRS" | grep -c . || true)
if [ -n "$NEW" ]; then
  N=$(printf '%s' "$NEW" | grep -c .)
  MSG="$N neue(r) Validierungsfehler (hass $VER, $BASE_N Bestandsfehler der Base ignoriert):
$NEW"
  python3 -c "import json,sys;print(json.dumps({'name':'ha-validate','status':'fail','message':sys.argv[1]}))" "$MSG"
else
  if [ "$BASE_N" -gt 0 ]; then
    emit pass "Keine neuen Validierungsfehler (hass $VER; $BASE_N Bestandsfehler der Base unverändert)"
  else
    emit pass "HA-Config valide (hass $VER)"
  fi
fi
