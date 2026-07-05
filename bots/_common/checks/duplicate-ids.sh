#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: duplicate-ids — doppelte Automation-IDs (Listen-Einträge `- id: X`).
# Häufiger Copy-Paste-Fehler; HA überschreibt dann still eine der Automationen.
# Warnt nur, wenn eine im PR hinzugefügte ID betroffen ist. Env: BASE_SHA, HEAD_SHA, DIFF_FILES_FILE.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'duplicate-ids','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
# git diff kennt kein --pathspec-from-file -> Datei-Liste als :(literal)-Pathspecs
# (kein Glob-/Magic-Parsing auf untrusted Dateinamen, Leerzeichen-sicher).
PATHSPEC=()
if [ -n "${DIFF_FILES_FILE:-}" ] && [ -s "${DIFF_FILES_FILE:-}" ]; then
  mapfile -t _PF < "$DIFF_FILES_FILE"
  PATHSPEC=(--)
  for _p in "${_PF[@]}"; do PATHSPEC+=(":(literal)$_p"); done
fi
mapfile -t NEW_IDS < <(git diff --unified=0 "$BASE_SHA" "$HEAD_SHA" "${PATHSPEC[@]}" \
  | grep -E '^\+[[:space:]]*-[[:space:]]+id:' \
  | sed -E "s/^\+[[:space:]]*-[[:space:]]+id:[[:space:]]*['\"]?([A-Za-z0-9_.-]+)['\"]?.*/\1/" \
  | grep -E '^[A-Za-z0-9_.-]+$' \
  | sort -u || true)
[ "${#NEW_IDS[@]}" -eq 0 ] && { emit skip "$(t "Keine neuen Automation-IDs im Diff" "No new automation IDs in the diff")"; exit 0; }
DUP=""
for id in "${NEW_IDS[@]}"; do
  N=$(grep -rhE "^[[:space:]]*-[[:space:]]+id:[[:space:]]*['\"]?${id}['\"]?([[:space:]]|$)" \
      --include='*.yaml' --include='*.yml' . 2>/dev/null | wc -l)
  [ "$N" -gt 1 ] && DUP="$DUP \`$id\`(${N}×)"
done
if [ -n "$DUP" ]; then
  emit warn "$(t "Automation-ID(s) mehrfach vergeben:$DUP" "Duplicate automation ID(s):$DUP")"
else
  emit pass "$(t "${#NEW_IDS[@]} neue Automation-ID(s) — alle eindeutig" "${#NEW_IDS[@]} new automation ID(s) — all unique")"
fi
