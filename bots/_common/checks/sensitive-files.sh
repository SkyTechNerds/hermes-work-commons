#!/bin/bash
# Check-Modul: sensitive-files — riskante Datei-Typen neu/geändert im PR (by name).
# Fängt, was der Inhalts-Scan nicht sieht: Key-Dateien, .env, secrets.yaml, Token-Files.
# Env: DIFF_FILES. cwd=REPO_DIR. Universell (alle Profile).
emit() { python3 -c "import json,sys;print(json.dumps({'name':'sensitive-files','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
HITS="$(printf '%s\n' "$DIFF_FILES" \
  | grep -iE '(^|/)(\.env(\..+)?|id_rsa[^/]*|id_ed25519[^/]*|id_ecdsa[^/]*|secrets\.ya?ml|[^/]*\.(pem|p12|pfx|keystore|jks|token))$' \
  | grep -viE '\.(example|sample|dist|template)$' || true)"
if [ -z "$HITS" ]; then
  emit pass "Keine sensiblen Datei-Typen im Diff"
else
  LIST="$(printf '%s\n' "$HITS" | head -5 | sed 's/`//g; s/^/`/; s/$/`/' | paste -sd ' ' -)"
  emit fail "Sensible Datei(en) im PR: $LIST — gehören die ins Repo?"
fi
