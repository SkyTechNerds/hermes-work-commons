#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: manifest — ALLE HA-Custom-Component manifest.json: Parse + Pflichtfelder + version. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'manifest','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
mapfile -t MANIFESTS < <(find custom_components -maxdepth 2 -name manifest.json 2>/dev/null | sort)
[ "${#MANIFESTS[@]}" -eq 0 ] && { emit fail "$(t "manifest.json fehlt komplett" "manifest.json missing entirely")"; exit 0; }
PROBLEMS=""
for MAN in "${MANIFESTS[@]}"; do
  if ! jq -e . "$MAN" >/dev/null 2>&1; then
    PROBLEMS="$PROBLEMS \`${MAN//\`/}\`(JSON kaputt)"
    continue
  fi
  MISSING=""
  for field in domain name version documentation issue_tracker codeowners requirements iot_class; do
    jq -e ".${field}" "$MAN" >/dev/null 2>&1 || MISSING="${MISSING} ${field}"
  done
  # HACS verlangt eine nicht-leere version (Release-Blocker wenn kaputt)
  VER=$(jq -r '.version // ""' "$MAN" 2>/dev/null)
  if [ -z "$MISSING" ] && [ -z "$VER" ]; then MISSING=" version(leer)"; fi
  [ -n "$MISSING" ] && PROBLEMS="$PROBLEMS \`${MAN//\`/}\`:${MISSING}"
done
if [ -z "$PROBLEMS" ]; then
  emit pass "$(t "${#MANIFESTS[@]} manifest.json geprüft — alle Pflichtfelder vorhanden" "${#MANIFESTS[@]} manifest.json checked — all required fields present")"
else
  emit fail "$(t "manifest-Probleme:$PROBLEMS" "manifest issues:$PROBLEMS")"
fi
