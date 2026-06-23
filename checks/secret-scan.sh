#!/bin/bash
# Secret-Scan: sucht Klartext-Passwoerter/API-Keys/Tokens im Diff
BASE="${BASE_REF:-${GITHUB_BASE_REF:-main}}"
HITS=$(git diff "origin/${BASE}..HEAD" 2>/dev/null \
  | grep -iE 'password[[:space:]]*:[[:space:]]*["'"'"'][^"'"'"'$]{6,}|api_key[[:space:]]*:[[:space:]]*["'"'"'][^"'"'"'$]{8,}|token[[:space:]]*:[[:space:]]*["'"'"'][^"'"'"'$]{8,}|secret[[:space:]]*=[[:space:]]*["'"'"'][^"'"'"']{8,}|ghp_[a-zA-Z0-9]{30,}|sk-[a-zA-Z0-9]{30,}' \
  | grep -vE '^[-+][[:space:]]*#|!secret|example|sample|test' || true)

if [ -z "$HITS" ]; then
  echo "status=pass" >> "$GITHUB_OUTPUT"
  echo "detail=Keine Klartext-Secrets im Diff" >> "$GITHUB_OUTPUT"
else
  COUNT=$(echo "$HITS" | wc -l)
  echo "status=fail" >> "$GITHUB_OUTPUT"
  {
    echo "detail<<EOF"
    echo "$HITS" | head -10
    echo "EOF"
  } >> "$GITHUB_OUTPUT"
  echo "::error::Secret-Scan: $COUNT mögliche Secrets gefunden"
fi
exit 0