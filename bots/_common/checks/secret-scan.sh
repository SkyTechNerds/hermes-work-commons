#!/bin/bash
# Check-Modul: secret-scan — Klartext-Secrets im Diff. Env: BASE_SHA, HEAD_SHA. cwd=REPO_DIR.
H=$(git diff "$BASE_SHA" "$HEAD_SHA" \
  | grep -iE 'password[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{6,}|api_key[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{8,}|token[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{8,}' \
  | grep -vE '^[-+][[:space:]]*#|!secret' || true)
if [ -z "$H" ]; then
  python3 -c 'import json;print(json.dumps({"name":"secret-scan","status":"pass","message":"Keine Klartext-Secrets im Diff"}))'
else
  N=$(echo "$H" | grep -c .)
  python3 -c "import json;print(json.dumps({'name':'secret-scan','status':'fail','message':'$N mögliche Klartext-Secrets'}))"
fi
