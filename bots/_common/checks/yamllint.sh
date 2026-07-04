#!/bin/bash
# Check-Modul: yamllint — nur GEÄNDERTE Zeilen, HA-taugliche Regeln. Env: BASE_SHA, HEAD_SHA, DIFF_FILES. cwd=REPO_DIR.
COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
emit() { python3 -c "import json,sys;print(json.dumps({'name':'yamllint','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
command -v yamllint >/dev/null 2>&1 || { emit skip "yamllint nicht installiert"; exit 0; }
mapfile -t YAML_FILES < <(printf '%s\n' "$DIFF_FILES" | grep -E '\.ya?ml$' || true)
[ "${#YAML_FILES[@]}" -eq 0 ] && { emit skip "Keine YAML-Dateien im Diff"; exit 0; }
YAML_ERR=$(python3 "$COMMON/yamllint-diff.py" "$BASE_SHA" "$HEAD_SHA" "${YAML_FILES[@]}" 2>/dev/null)
RC=$?
[ "$RC" -ne 0 ] && { emit warn "yamllint-Lauf fehlgeschlagen (Exit $RC)"; exit 0; }
if [ -z "$YAML_ERR" ]; then
  emit pass "${#YAML_FILES[@]} YAML-Datei(en) — keine neuen Lint-Fehler in den geänderten Zeilen"
else
  emit fail "$(printf '%s\n' "$YAML_ERR" | grep -c .) neue Lint-Fehler in geänderten Zeilen"
fi
