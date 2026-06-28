#!/bin/bash
# Check-Modul: translations — en.json-Pflicht + Key-Konsistenz. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'translations','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
TDIR=$(find custom_components -maxdepth 2 -type d -name translations 2>/dev/null | head -1)
[ -z "$TDIR" ] && { emit skip "Kein translations/-Verzeichnis"; exit 0; }
EN="$TDIR/en.json"
[ -f "$EN" ] || { emit warn "en.json fehlt - keine Pflicht-Sprache"; exit 0; }
LANG_FILES=$(find "$TDIR" -name '*.json' | wc -l)
EN_KEYS=$(jq -r '[.. | objects | keys[]] | unique | length' "$EN" 2>/dev/null || echo 0)
MISMATCH=""
for lf in "$TDIR"/*.json; do
  [ "$lf" = "$EN" ] && continue
  LK=$(jq -r '[.. | objects | keys[]] | unique | length' "$lf" 2>/dev/null || echo 0)
  [ "$LK" -ne "$EN_KEYS" ] && MISMATCH="${MISMATCH} $(basename "$lf" .json)(${LK} vs ${EN_KEYS})"
done
if [ -z "$MISMATCH" ]; then
  emit pass "${LANG_FILES} Sprachen, alle mit ${EN_KEYS} Keys konsistent"
else
  emit warn "Translations-Key-Mismatch:${MISMATCH}"
fi
