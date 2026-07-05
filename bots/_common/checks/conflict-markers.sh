#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: conflict-markers — versehentlich committete Merge-Konflikt-Marker.
# Env: BASE_SHA, HEAD_SHA, DIFF_FILES_FILE. cwd=REPO_DIR. Universell (alle Profile).
emit() { python3 -c "import json,sys;print(json.dumps({'name':'conflict-markers','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
# git diff kennt kein --pathspec-from-file -> Datei-Liste als :(literal)-Pathspecs
# (kein Glob-/Magic-Parsing auf untrusted Dateinamen, Leerzeichen-sicher).
PATHSPEC=()
if [ -n "${DIFF_FILES_FILE:-}" ] && [ -s "${DIFF_FILES_FILE:-}" ]; then
  mapfile -t _PF < "$DIFF_FILES_FILE"
  PATHSPEC=(--)
  for _p in "${_PF[@]}"; do PATHSPEC+=(":(literal)$_p"); done
fi
N=$(git diff --unified=0 "$BASE_SHA" "$HEAD_SHA" "${PATHSPEC[@]}" \
  | grep -cE '^\+(<{7}( |$)|={7}$|>{7}( |$))' || true)
if [ "${N:-0}" -eq 0 ]; then
  emit pass "$(t "Keine Merge-Konflikt-Marker" "No merge conflict markers")"
else
  emit fail "$(t "$N Merge-Konflikt-Marker (<<<<<<</=======/>>>>>>>) in hinzugefügten Zeilen" "$N merge conflict markers (<<<<<<</=======/>>>>>>>) in added lines")"
fi
