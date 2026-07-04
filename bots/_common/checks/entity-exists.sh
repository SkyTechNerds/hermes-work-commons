#!/bin/bash
# Check-Modul: entity-exists — referenzierte entity_ids in NEUEN Zeilen gegen die
# Home-Assistant-Instanz prüfen (GET /api/states). Fängt Tippfehler in Entity-IDs,
# die häufigste Fehlerklasse in HA-Configs.
# Config: /etc/hermes-work-app/ha-url + /etc/hermes-work-app/ha-token (chmod 600).
# Ohne Config oder bei nicht erreichbarer Instanz: skip (kein fail — externe Abhängigkeit).
# Env: BASE_SHA, HEAD_SHA, DIFF_FILES. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'entity-exists','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }

HA_URL_FILE=/etc/hermes-work-app/ha-url
HA_TOKEN_FILE=/etc/hermes-work-app/ha-token
if [ ! -s "$HA_URL_FILE" ] || [ ! -s "$HA_TOKEN_FILE" ]; then
  emit skip "HA-Zugang nicht konfiguriert (ha-url/ha-token in /etc/hermes-work-app/)"
  exit 0
fi

YAML_FILES=$(echo "$DIFF_FILES" | grep -E '\.(ya?ml)$' || true)
[ -z "$YAML_FILES" ] && { emit skip "Keine YAML-Dateien im Diff"; exit 0; }

OUT="$(YAML_FILES="$YAML_FILES" BASE_SHA="$BASE_SHA" HEAD_SHA="$HEAD_SHA" \
      HA_URL="$(cat "$HA_URL_FILE")" HA_TOKEN="$(cat "$HA_TOKEN_FILE")" python3 <<'PY'
import json, os, re, subprocess, sys, urllib.request

base, head = os.environ["BASE_SHA"], os.environ["HEAD_SHA"]
DOMAINS = ("light|switch|binary_sensor|sensor|input_boolean|input_number|input_select|input_text|input_datetime|"
           "automation|script|scene|person|device_tracker|climate|cover|media_player|lock|fan|vacuum|camera|"
           "alarm_control_panel|timer|counter|zone|group|number|select|button|siren|humidifier|weather|"
           "update|calendar|todo|notify|remote|water_heater|valve|event|text|image|lawn_mower|wake_word")
ENT_RE = re.compile(r'\b((?:%s)\.[a-z0-9_]+)\b' % DOMAINS)

# 1) Live-Entity-Liste holen (einmal)
try:
    req = urllib.request.Request(os.environ["HA_URL"].rstrip("/") + "/api/states",
                                 headers={"Authorization": "Bearer " + os.environ["HA_TOKEN"]})
    with urllib.request.urlopen(req, timeout=10) as r:
        live = {s["entity_id"] for s in json.load(r)}
except Exception as e:
    print("__HA_UNREACHABLE__ " + str(e)[:120])
    sys.exit(0)

# 2) entity_ids aus den +Zeilen des Diffs ziehen (mit Datei:Zeile)
missing = []
seen = set()
for f in os.environ["YAML_FILES"].split():
    diff = subprocess.run(["git", "diff", "--unified=0", base, head, "--", f],
                          capture_output=True, text=True).stdout
    lineno = 0
    for raw in diff.splitlines():
        m = re.match(r'^@@ -\d+(?:,\d+)? \+(\d+)', raw)
        if m:
            lineno = int(m.group(1)) - 1
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            lineno += 1
            code = raw[1:]
            if code.lstrip().startswith("#") or "{{" in code or "!secret" in code:
                continue
            for ent in ENT_RE.findall(code):
                if ent not in live and ent not in seen:
                    seen.add(ent)
                    missing.append(f"{f}:{lineno} `{ent}` existiert nicht in der HA-Instanz")

for x in missing:
    print(x)
PY
)"
case "$OUT" in
  __HA_UNREACHABLE__*)
    emit skip "HA-Instanz nicht erreichbar — Entity-Prüfung übersprungen"; exit 0 ;;
esac
if [ -z "$OUT" ]; then
  emit pass "Alle referenzierten Entities existieren in der HA-Instanz"
else
  N=$(echo "$OUT" | grep -c .)
  python3 -c "import json,sys;print(json.dumps({'name':'entity-exists','status':'warn','message':sys.argv[1]}))" "$N unbekannte Entity/Entities:
$OUT"
fi
