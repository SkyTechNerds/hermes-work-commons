#!/bin/bash
# Check-Modul: yamllint — nur GEÄNDERTE Zeilen, HA-taugliche Regeln. Env: BASE_SHA, HEAD_SHA, DIFF_FILES. cwd=REPO_DIR.
COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
emit() { python3 -c "import json,sys;print(json.dumps({'name':'yamllint','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
command -v yamllint >/dev/null 2>&1 || { emit skip "$(t "yamllint nicht installiert" "yamllint not installed")"; exit 0; }
mapfile -t YAML_FILES < <(printf '%s\n' "$DIFF_FILES" | grep -E '\.ya?ml$' || true)
[ "${#YAML_FILES[@]}" -eq 0 ] && { emit skip "$(t "Keine YAML-Dateien im Diff" "No YAML files in the diff")"; exit 0; }
YAML_ERR=$(python3 "$COMMON/yamllint-diff.py" "$BASE_SHA" "$HEAD_SHA" "${YAML_FILES[@]}" 2>/dev/null)
RC=$?
[ "$RC" -ne 0 ] && { emit warn "$(t "yamllint-Lauf fehlgeschlagen (Exit $RC)" "yamllint run failed (exit $RC)")"; exit 0; }
if [ -z "$YAML_ERR" ]; then
  emit pass "$(t "${#YAML_FILES[@]} YAML-Datei(en) — keine neuen Lint-Fehler in den geänderten Zeilen" "${#YAML_FILES[@]} YAML file(s) — no new lint errors in the changed lines")"
else
  [ -n "${CM_INLINE:-}" ] && printf '%s\n' "$YAML_ERR" | CM_CHECK=yamllint CM_SEV=fail python3 "$COMMON/to-inline.py" >> "$CM_INLINE" 2>/dev/null
  emit fail "$(printf '%s\n' "$YAML_ERR" | grep -c .) $(t "neue Lint-Fehler in geänderten Zeilen — inline markiert" "new lint errors in changed lines — flagged inline")"
fi
