#!/bin/bash
# Lint: fuehrt projekt-spezifische Linter aus
CHANGED=$(git diff --name-only "origin/${{ github.base_ref }}..HEAD")
YAML_FILES=$(echo "$CHANGED" | grep -E '\.(ya?ml)$' || true)
PY_FILES=$(echo "$CHANGED" | grep -E '\.py$' || true)
JS_FILES=$(echo "$CHANGED" | grep -E '\.(js|ts)x?$' || true)

FAILED=0
SUMMARY=""

if [ -n "$YAML_FILES" ]; then
  OUT=$(yamllint -f parsable $YAML_FILES 2>&1 || true)
  if [ -n "$OUT" ]; then
    FAILED=1
    SUMMARY="$SUMMARY\nyamllint: $(echo "$OUT" | wc -l) Fehler"
    echo "$OUT" | head -10
  fi
fi

if [ -n "$PY_FILES" ] && command -v ruff >/dev/null 2>&1; then
  OUT=$(ruff check $PY_FILES 2>&1 || true)
  if [ -n "$OUT" ]; then
    FAILED=1
    SUMMARY="$SUMMARY\nruff: $(echo "$OUT" | wc -l) Probleme"
  fi
fi

if [ -n "$JS_FILES" ] && command -v eslint >/dev/null 2>&1; then
  OUT=$(eslint $JS_FILES 2>&1 || true)
  if [ -n "$OUT" ]; then
    FAILED=1
    SUMMARY="$SUMMARY\neslint: $(echo "$OUT" | wc -l) Probleme"
  fi
fi

if [ "$FAILED" -eq 0 ]; then
  echo "status=pass" >> "$GITHUB_OUTPUT"
  echo "Lint OK ($YAML_FILES|$PY_FILES|$JS_FILES)"
else
  echo "status=fail" >> "$GITHUB_OUTPUT"
  echo -e "$SUMMARY"
fi
