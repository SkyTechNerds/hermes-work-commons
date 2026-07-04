#!/bin/bash
# Check-Modul: secret-refs — jedes im Diff hinzugefügte `!secret X` muss einen Key in
# secrets.yaml haben (fehlender Key = HA bootet nicht). Skip wenn secrets.yaml nicht
# im Repo liegt (üblich: gitignored). Env: BASE_SHA, HEAD_SHA, DIFF_FILES_FILE, REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'secret-refs','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
[ -f "$REPO_DIR/secrets.yaml" ] || { emit skip "secrets.yaml nicht im Repo (gitignored) — nicht prüfbar"; exit 0; }
# git diff kennt kein --pathspec-from-file -> Datei-Liste als :(literal)-Pathspecs
# (kein Glob-/Magic-Parsing auf untrusted Dateinamen, Leerzeichen-sicher).
PATHSPEC=()
if [ -n "${DIFF_FILES_FILE:-}" ] && [ -s "${DIFF_FILES_FILE:-}" ]; then
  mapfile -t _PF < "$DIFF_FILES_FILE"
  PATHSPEC=(--)
  for _p in "${_PF[@]}"; do PATHSPEC+=(":(literal)$_p"); done
fi
mapfile -t REFS < <(git diff --unified=0 "$BASE_SHA" "$HEAD_SHA" "${PATHSPEC[@]}" \
  | grep -E '^\+' | grep -oE '![[:space:]]*secret[[:space:]]+[A-Za-z0-9_]+' \
  | awk '{print $NF}' | sort -u || true)
[ "${#REFS[@]}" -eq 0 ] && { emit skip "Keine neuen !secret-Referenzen im Diff"; exit 0; }
MISSING=""
for ref in "${REFS[@]}"; do
  grep -qE "^${ref}[[:space:]]*:" "$REPO_DIR/secrets.yaml" || MISSING="$MISSING \`$ref\`"
done
if [ -n "$MISSING" ]; then
  emit fail "!secret-Referenz(en) ohne Key in secrets.yaml:$MISSING"
else
  emit pass "${#REFS[@]} !secret-Referenz(en) — alle Keys vorhanden"
fi
