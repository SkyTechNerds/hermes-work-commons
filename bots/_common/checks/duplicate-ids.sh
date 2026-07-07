#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: duplicate-ids — doppelte Automation-IDs (`- id: X`). Betroffene neue ID
# -> Inline an der Zeile. Env: BASE_SHA, HEAD_SHA, DIFF_FILES_FILE. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'duplicate-ids','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATHSPEC=()
if [ -n "${DIFF_FILES_FILE:-}" ] && [ -s "${DIFF_FILES_FILE:-}" ]; then
  mapfile -t _PF < "$DIFF_FILES_FILE"; PATHSPEC=(--)
  for _p in "${_PF[@]}"; do PATHSPEC+=(":(literal)$_p"); done
fi
mapfile -t NEW_IDS < <(git diff --unified=0 "$BASE_SHA" "$HEAD_SHA" "${PATHSPEC[@]}" \
  | grep -E '^\+[[:space:]]*-[[:space:]]+id:' \
  | sed -E "s/^\+[[:space:]]*-[[:space:]]+id:[[:space:]]*['\"]?([A-Za-z0-9_.-]+)['\"]?.*/\1/" \
  | grep -E '^[A-Za-z0-9_.-]+$' | sort -u || true)
[ "${#NEW_IDS[@]}" -eq 0 ] && { emit skip "$(t "Keine neuen Automation-IDs im Diff" "No new automation IDs in the diff")"; exit 0; }
DUP_IDS=""
for id in "${NEW_IDS[@]}"; do
  N=$(grep -rhE "^[[:space:]]*-[[:space:]]+id:[[:space:]]*['\"]?${id}['\"]?([[:space:]]|$)" \
      --include='*.yaml' --include='*.yml' . 2>/dev/null | wc -l)
  [ "$N" -gt 1 ] && DUP_IDS="$DUP_IDS $id"
done
if [ -n "$DUP_IDS" ]; then
  ALT="$(echo $DUP_IDS | tr ' ' '|')"
  LABEL="$(t "Automation-ID mehrfach vergeben (überschreibt still eine andere)" "duplicate automation ID (silently overrides another)")"
  [ -n "${CM_INLINE:-}" ] && git diff --unified=0 "$BASE_SHA" "$HEAD_SHA" "${PATHSPEC[@]}" \
    | python3 "$D/diff-locate.py" "-\\s+id:\\s*['\"]?($ALT)\\b" --label "$LABEL" \
    | CM_CHECK=duplicate-ids CM_SEV=warn python3 "$D/to-inline.py" >> "$CM_INLINE" 2>/dev/null
  ND=$(echo $DUP_IDS | wc -w)
  emit warn "$(t "$ND Automation-ID(s) mehrfach vergeben — inline markiert" "$ND automation ID(s) duplicated — flagged inline")"
else
  emit pass "$(t "${#NEW_IDS[@]} neue Automation-ID(s) — alle eindeutig" "${#NEW_IDS[@]} new automation ID(s) — all unique")"
fi
