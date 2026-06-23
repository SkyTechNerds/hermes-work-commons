#!/bin/bash
# Lint: fuehrt projekt-spezifische Linter aus
CHANGED=$(git diff --name-only "origin/${BASE_REF:-${GITHUB_BASE_REF:-main}}..HEAD")
YAML_FILES=$(echo "$CHANGED" | grep -E '\.(ya?ml)$' || true)
PY_FILES=$(echo "$CHANGED" | grep -E '\.py$' || true)
JS_FILES=$(echo "$CHANGED" | grep -E '\.(js|ts)x?$' || true)
CSS_FILES=$(echo "$CHANGED" | grep -E '\.css$' || true)

FAILED=0
SUMMARY=""

if [ -n "$YAML_FILES" ]; then
  OUT=$(yamllint -f parsable $YAML_FILES 2>&1 || true)
  if [ -n "$OUT" ]; then
    FAILED=1
    SUMMARY="$SUMMARY\n$YAML_FILES"
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
  OUT=$(eslint --no-warn-ignored $JS_FILES 2>&1 || true)
  if [ -n "$OUT" ]; then
    FAILED=1
    SUMMARY="$SUMMARY\neslint: $(echo "$OUT" | wc -l) Probleme"
  fi
fi

if [ -n "$CSS_FILES" ] && command -v stylelint >/dev/null 2>&1; then
  OUT=$(stylelint $CSS_FILES 2>&1 || true)
  if [ -n "$OUT" ]; then
    FAILED=1
    SUMMARY="$SUMMARY\nstylelint: $(echo "$OUT" | wc -l) Probleme"
  fi
fi

# Custom lint command override
if [ -n "$LINT_COMMAND" ]; then
  FILES_ALL="$(echo -e "$YAML_FILES\n$PY_FILES\n$JS_FILES\n$CSS_FILES" | grep -v '^$' || true)"
  if [ -n "$FILES_ALL" ]; then
    OUT=$(sh -c "$LINT_COMMAND $FILES_ALL" 2>&1 || true)
    if [ -n "$OUT" ]; then
      FAILED=1
      SUMMARY="$SUMMARY\ncustom-lint: $(echo "$OUT" | wc -l) Probleme"
    fi
  fi
fi

if [ "$FAILED" -eq 0 ]; then
  echo "status=pass" >> "$GITHUB_OUTPUT"
  count=$(echo "$YAML_FILES $PY_FILES $JS_FILES $CSS_FILES" | wc -w)
  echo "detail=Lint OK ($count Files)" >> "$GITHUB_OUTPUT"
else
  echo "status=fail" >> "$GITHUB_OUTPUT"
  echo -e "$SUMMARY" >> "$GITHUB_OUTPUT"
fi
