#!/bin/bash
# Secret-Scan: sucht Klartext-Passwoerter/API-Keys/Tokens im Diff
HITS_FILE=$(git diff "origin/${{ github.base_ref }}..HEAD" \
  | grep -iE 'password[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{6,}|api_key[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{8,}|token[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{8,}' \
  | grep -vE '^[-+][[:space:]]*#|!secret' || true)
HITS=$(cat "$HITS_FILE")
if [ -z "$HITS" ]; then
  echo "status=pass" >> "$GITHUB_OUTPUT"
  echo "Keine Klartext-Secrets im Diff"
else
  echo "status=fail" >> "$GITHUB_OUTPUT"
  echo "$HITS" | head -10
  exit 0  # exit 0 damit andere Checks weiterlaufen
fi
