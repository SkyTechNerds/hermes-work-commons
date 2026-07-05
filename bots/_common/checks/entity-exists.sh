#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: entity-exists — referenzierte entity_ids in NEUEN Zeilen gegen die
# Home-Assistant-Instanz prüfen (GET /api/states). Fängt Tippfehler in Entity-IDs.
#
# Konfiguration BEVORZUGT im Repo (.codemole.yml, kein Server-Zugriff nötig):
#   entity-exists:
#     ha_url: "http://ha.local:8123"
#     ha_token: "enc:v1:<blob>"    # Long-Lived Token, verschlüsselt via Browser-Tool
#                                   # (https://web.skycryer.com/codemole/docs/#secrets)
# Der Blob ist RSA-OAEP(SHA-256)-verschlüsselt gegen den CodeMole-Public-Key;
# entschlüsselt wird serverseitig mit /etc/hermes-work-app/secrets-key.pem.
# Fallback (legacy): /etc/hermes-work-app/ha-url + ha-token.
# Ohne Config oder bei nicht erreichbarer Instanz: skip (externe Abhängigkeit).
# Env: BASE_SHA, HEAD_SHA, DIFF_FILES, RESOLVE (optional). cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'entity-exists','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }

COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECKEY=/etc/hermes-work-app/secrets-key.pem

# --- Config auflösen: .codemole.yml (via RESOLVE) -> Fallback Server-Dateien ---
RES="${RESOLVE:-}"
[ -z "$RES" ] && RES="$(python3 "$COMMON/resolve-profile.py" "${REPO_DIR:-.}" "${REPO:-x/y}" 2>/dev/null)"
HA_URL="$(printf '%s' "$RES" | python3 -c 'import sys,json
try: o=(json.load(sys.stdin).get("options") or {}).get("entity-exists") or {}
except Exception: o={}
print(o.get("ha_url") or "")' 2>/dev/null)"
HA_TOKEN_RAW="$(printf '%s' "$RES" | python3 -c 'import sys,json
try: o=(json.load(sys.stdin).get("options") or {}).get("entity-exists") or {}
except Exception: o={}
print(o.get("ha_token") or "")' 2>/dev/null)"

HA_TOKEN=""
case "$HA_TOKEN_RAW" in
  enc:v1:*)
    if [ -f "$SECKEY" ]; then
      HA_TOKEN="$(printf '%s' "${HA_TOKEN_RAW#enc:v1:}" | base64 -d 2>/dev/null | \
        openssl pkeyutl -decrypt -inkey "$SECKEY" -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 2>/dev/null)"
      [ -z "$HA_TOKEN" ] && { emit warn "$(t "entity-exists: ha_token konnte nicht entschlüsselt werden — Blob mit dem aktuellen Public Key neu erzeugen (Doku: Secrets)" "entity-exists: ha_token could not be decrypted — re-create the blob with the current public key (docs: Secrets)")"; exit 0; }
    fi ;;
  "") : ;;
  *) emit warn "$(t "entity-exists: ha_token muss verschlüsselt sein (enc:v1:… via Browser-Tool, Doku: Secrets) — Klartext-Token werden ignoriert" "entity-exists: ha_token must be encrypted (enc:v1:… via the browser tool, docs: Secrets) — plaintext tokens are ignored")"; exit 0 ;;
esac

# Fallback: serverseitige Dateien (legacy)
[ -z "$HA_URL" ] && [ -s /etc/hermes-work-app/ha-url ] && HA_URL="$(cat /etc/hermes-work-app/ha-url)"
[ -z "$HA_TOKEN" ] && [ -s /etc/hermes-work-app/ha-token ] && HA_TOKEN="$(cat /etc/hermes-work-app/ha-token)"

if [ -z "$HA_URL" ] || [ -z "$HA_TOKEN" ]; then
  emit skip "$(t "Optional — HA-Zugang nicht konfiguriert ([Anleitung](https://web.skycryer.com/codemole/docs/#secrets))" "Optional — HA access not configured ([guide](https://web.skycryer.com/codemole/docs/en/#secrets))")"
  exit 0
fi

YAML_FILES=$(echo "$DIFF_FILES" | grep -E '\.(ya?ml)$' || true)
[ -z "$YAML_FILES" ] && { emit skip "$(t "Keine YAML-Dateien im Diff" "No YAML files in the diff")"; exit 0; }

OUT="$(YAML_FILES="$YAML_FILES" BASE_SHA="$BASE_SHA" HEAD_SHA="$HEAD_SHA" \
      HA_URL="$HA_URL" HA_TOKEN="$HA_TOKEN" python3 <<'PY'
import json, os, re, subprocess, sys, urllib.request

base, head = os.environ["BASE_SHA"], os.environ["HEAD_SHA"]
DOMAINS = ("light|switch|binary_sensor|sensor|input_boolean|input_number|input_select|input_text|input_datetime|"
           "automation|script|scene|person|device_tracker|climate|cover|media_player|lock|fan|vacuum|camera|"
           "alarm_control_panel|timer|counter|zone|group|number|select|button|siren|humidifier|weather|"
           "update|calendar|todo|notify|remote|water_heater|valve|event|text|image|lawn_mower|wake_word")
ENT_RE = re.compile(r'\b((?:%s)\.[a-z0-9_]+)\b' % DOMAINS)

try:
    req = urllib.request.Request(os.environ["HA_URL"].rstrip("/") + "/api/states",
                                 headers={"Authorization": "Bearer " + os.environ["HA_TOKEN"]})
    with urllib.request.urlopen(req, timeout=10) as r:
        live = {s["entity_id"] for s in json.load(r)}
except Exception as e:
    print("__HA_UNREACHABLE__ " + type(e).__name__)
    sys.exit(0)

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
                    suffix = "does not exist in the HA instance" if os.environ.get("CODEMOLE_LANG", "de") == "en" else "existiert nicht in der HA-Instanz"
                    missing.append(f"{f}:{lineno} `{ent}` {suffix}")

for x in missing:
    print(x)
PY
)"
case "$OUT" in
  __HA_UNREACHABLE__*)
    emit skip "$(t "HA-Instanz nicht erreichbar — Entity-Prüfung übersprungen" "HA instance not reachable — entity check skipped")"; exit 0 ;;
esac
if [ -z "$OUT" ]; then
  emit pass "$(t "Alle referenzierten Entities existieren in der HA-Instanz" "All referenced entities exist in the HA instance")"
else
  N=$(echo "$OUT" | grep -c .)
  python3 -c "import json,sys;print(json.dumps({'name':'entity-exists','status':'warn','message':sys.argv[1]}))" "$(t "$N unbekannte Entity/Entities:" "$N unknown entity/entities:")
$OUT"
fi
