#!/bin/bash
# Check-Modul: yamllint — nur GEÄNDERTE Zeilen, HA-taugliche Regeln. Env: BASE_SHA, HEAD_SHA, DIFF_FILES. cwd=REPO_DIR.
COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
emit() { python3 -c "import json,sys;print(json.dumps({'name':'yamllint','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
YAML_FILES=$(echo "$DIFF_FILES" | grep -E '\.(ya?ml)$' || true)
if [ -z "$YAML_FILES" ]; then emit skip "Keine YAML-Dateien im Diff"; exit 0; fi
YAML_ERR=$(python3 "$COMMON/yamllint-diff.py" "$BASE_SHA" "$HEAD_SHA" $YAML_FILES 2>/dev/null || true)
if [ -z "$YAML_ERR" ]; then
  emit pass "$(echo "$YAML_FILES" | grep -c .) YAML-Datei(en) — keine neuen Lint-Fehler in den geänderten Zeilen"
else
  emit fail "$(echo "$YAML_ERR" | grep -c .) neue Lint-Fehler in geänderten Zeilen"
fi
