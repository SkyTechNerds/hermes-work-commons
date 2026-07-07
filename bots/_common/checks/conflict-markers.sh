#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: conflict-markers — versehentlich committete Merge-Konflikt-Marker.
# Zeilen-lokal -> Inline-Kommentar an der Marker-Zeile. Env: BASE_SHA, HEAD_SHA, DIFF_FILES_FILE. Universell.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'conflict-markers','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATHSPEC=()
if [ -n "${DIFF_FILES_FILE:-}" ] && [ -s "${DIFF_FILES_FILE:-}" ]; then
  mapfile -t _PF < "$DIFF_FILES_FILE"; PATHSPEC=(--)
  for _p in "${_PF[@]}"; do PATHSPEC+=(":(literal)$_p"); done
fi
LABEL="$(t "übrig gebliebener Merge-Konflikt-Marker" "leftover merge conflict marker")"
LOC="$(git diff --unified=0 "$BASE_SHA" "$HEAD_SHA" "${PATHSPEC[@]}" \
  | python3 "$D/diff-locate.py" '^(<{7}( |$)|={7}$|>{7}( |$))' --label "$LABEL")"
N=$(printf '%s\n' "$LOC" | grep -c .)
if [ "$N" -eq 0 ]; then
  emit pass "$(t "Keine Merge-Konflikt-Marker" "No merge conflict markers")"
else
  [ -n "${CM_INLINE:-}" ] && printf '%s\n' "$LOC" | CM_CHECK=conflict-markers CM_SEV=fail python3 "$D/to-inline.py" >> "$CM_INLINE" 2>/dev/null
  emit fail "$(t "$N Merge-Konflikt-Marker in hinzugefügten Zeilen — inline markiert" "$N merge conflict markers in added lines — flagged inline")"
fi
