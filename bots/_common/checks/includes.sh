#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: includes — verwaiste !include-Referenzen. Env: BASE_SHA, HEAD_SHA, REPO_DIR, DIFF_FILES_FILE. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'includes','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
# git diff kennt kein --pathspec-from-file -> Datei-Liste als :(literal)-Pathspecs
# (kein Glob-/Magic-Parsing auf untrusted Dateinamen, Leerzeichen-sicher).
PATHSPEC=()
if [ -n "${DIFF_FILES_FILE:-}" ] && [ -s "${DIFF_FILES_FILE:-}" ]; then
  mapfile -t _PF < "$DIFF_FILES_FILE"
  PATHSPEC=(--)
  for _p in "${_PF[@]}"; do PATHSPEC+=(":(literal)$_p"); done
fi
mapfile -t INCLUDE_REFS < <(git diff "$BASE_SHA" "$HEAD_SHA" "${PATHSPEC[@]}" \
  | grep -oE '![[:space:]]*include(_dir_(list|named|merge_list|merge_named))?[[:space:]]+[^[:space:]]+' \
  | sed -E 's/^![[:space:]]*include(_dir_(list|named|merge_list|merge_named))?[[:space:]]+//;s/^["\x27]//;s/["\x27]$//' \
  | sort -u || true)
[ "${#INCLUDE_REFS[@]}" -eq 0 ] && { emit skip "$(t "Keine include-Änderungen im Diff" "No include changes in the diff")"; exit 0; }
MISSING=""
for ref in "${INCLUDE_REFS[@]}"; do
  # include_dir_* referenziert Verzeichnisse, !include Dateien
  [ -e "$REPO_DIR/$ref" ] || MISSING="$MISSING \`${ref//\`/}\`"
done
if [ -n "$MISSING" ]; then
  # Dateinamen kommen aus dem (untrusted) Diff -> in Code-Spans, keine @mention/Markdown-Injection
  emit fail "$(t "Fehlende include-Ziele:$MISSING" "Missing include targets:$MISSING")"
else
  emit pass "$(t "Alle include-Referenzen aufgelöst" "All include references resolved")"
fi
