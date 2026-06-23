#!/bin/bash
# Diff-Size: warnt bei zu grossen PRs
BASE="${BASE_REF:-${GITHUB_BASE_REF:-main}}"
STAT=$(git diff --shortstat "origin/${BASE}..HEAD")
FILES=$(git diff --name-only "origin/${BASE}..HEAD" | wc -l)
ADDED=$(git diff --numstat "origin/${BASE}..HEAD" | awk '{s+=$1} END {print s+0}')
if [ "$ADDED" -gt 1000 ] || [ "$FILES" -gt 30 ]; then
  echo "status=warn" >> "$GITHUB_OUTPUT"
  echo "detail=Diff +${ADDED} Zeilen in ${FILES} Dateien" >> "$GITHUB_OUTPUT"
else
  echo "status=pass" >> "$GITHUB_OUTPUT"
  echo "detail=Diff +${ADDED} in ${FILES} Dateien" >> "$GITHUB_OUTPUT"
fi
