#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: secret-refs — jedes hinzugefügte `!secret X` braucht einen Key in secrets.yaml.
# Fehlende -> Inline an der Referenz-Zeile. Env: BASE_SHA, HEAD_SHA, DIFF_FILES_FILE, REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'secret-refs','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO_DIR/secrets.yaml" ] || { emit skip "$(t "secrets.yaml nicht im Repo (gitignored) — nicht prüfbar" "secrets.yaml not in the repo (gitignored) — cannot check")"; exit 0; }
PATHSPEC=()
if [ -n "${DIFF_FILES_FILE:-}" ] && [ -s "${DIFF_FILES_FILE:-}" ]; then
  mapfile -t _PF < "$DIFF_FILES_FILE"; PATHSPEC=(--)
  for _p in "${_PF[@]}"; do PATHSPEC+=(":(literal)$_p"); done
fi
mapfile -t REFS < <(git diff --unified=0 "$BASE_SHA" "$HEAD_SHA" "${PATHSPEC[@]}" \
  | grep -E '^\+' | grep -oE '![[:space:]]*secret[[:space:]]+[A-Za-z0-9_]+' \
  | awk '{print $NF}' | sort -u || true)
[ "${#REFS[@]}" -eq 0 ] && { emit skip "$(t "Keine neuen !secret-Referenzen im Diff" "No new !secret references in the diff")"; exit 0; }
MISSING_REFS=""
for ref in "${REFS[@]}"; do
  grep -qE "^${ref}[[:space:]]*:" "$REPO_DIR/secrets.yaml" || MISSING_REFS="$MISSING_REFS $ref"
done
if [ -n "$MISSING_REFS" ]; then
  ALT="$(echo $MISSING_REFS | tr ' ' '|')"
  LABEL="$(t "!secret ohne passenden Key in secrets.yaml" "!secret without a matching key in secrets.yaml")"
  [ -n "${CM_INLINE:-}" ] && git diff --unified=0 "$BASE_SHA" "$HEAD_SHA" "${PATHSPEC[@]}" \
    | python3 "$D/diff-locate.py" "!\\s*secret\\s+($ALT)\\b" --label "$LABEL" \
    | CM_CHECK=secret-refs CM_SEV=fail python3 "$D/to-inline.py" >> "$CM_INLINE" 2>/dev/null
  NM=$(echo $MISSING_REFS | wc -w)
  emit fail "$(t "$NM !secret-Referenz(en) ohne Key in secrets.yaml — inline markiert" "$NM !secret reference(s) without a key in secrets.yaml — flagged inline")"
else
  emit pass "$(t "${#REFS[@]} !secret-Referenz(en) — alle Keys vorhanden" "${#REFS[@]} !secret reference(s) — all keys present")"
fi
