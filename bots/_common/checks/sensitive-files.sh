#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: sensitive-files — riskante Datei-Typen neu/geändert im PR (by name).
# Fängt, was der Inhalts-Scan nicht sieht: Key-Dateien, .env, secrets.yaml, Token-Files.
# Env: DIFF_FILES. cwd=REPO_DIR. Universell (alle Profile).
emit() { python3 -c "import json,sys;print(json.dumps({'name':'sensitive-files','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
HITS="$(printf '%s\n' "$DIFF_FILES" \
  | grep -iE '(^|/)(\.env(\..+)?|id_rsa[^/]*|id_ed25519[^/]*|id_ecdsa[^/]*|secrets\.ya?ml|[^/]*\.(pem|p12|pfx|keystore|jks|token))$' \
  | grep -viE '\.(example|sample|dist|template)$' || true)"
if [ -z "$HITS" ]; then
  emit pass "$(t "Keine sensiblen Datei-Typen im Diff" "No sensitive file types in the diff")"
else
  LIST="$(printf '%s\n' "$HITS" | head -5 | sed 's/`//g; s/^/`/; s/$/`/' | paste -sd ' ' -)"
  emit fail "$(t "Sensible Datei(en) im PR: $LIST — gehören die ins Repo?" "Sensitive file(s) in the PR: $LIST — do these belong in the repo?")"
fi
