#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: json-valid — geänderte .json-Dateien müssen als Ganzes parsen
# (jq -e '.feld' allein lässt kaputtes JSON teils durchrutschen). Env: DIFF_FILES. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'json-valid','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
mapfile -t JSON_FILES < <(printf '%s\n' "$DIFF_FILES" | grep -E '\.json$' || true)
[ "${#JSON_FILES[@]}" -eq 0 ] && { emit skip "$(t "Keine JSON-Dateien im Diff" "No JSON files in the diff")"; exit 0; }
BROKEN=""
CHECKED=0
for f in "${JSON_FILES[@]}"; do
  [ -f "$f" ] || continue
  CHECKED=$((CHECKED + 1))
  python3 -c "import json,sys;json.load(open(sys.argv[1],encoding='utf-8'))" "$f" 2>/dev/null \
    || BROKEN="$BROKEN \`${f//\`/}\`"
done
[ "$CHECKED" -eq 0 ] && { emit skip "$(t "Nur gelöschte JSON-Dateien im Diff" "Only deleted JSON files in the diff")"; exit 0; }
if [ -z "$BROKEN" ]; then
  emit pass "$(t "$CHECKED JSON-Datei(en) parsen sauber" "$CHECKED JSON file(s) parse cleanly")"
else
  emit fail "$(t "Ungültiges JSON:$BROKEN" "Invalid JSON:$BROKEN")"
fi
