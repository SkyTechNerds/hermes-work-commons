#!/bin/bash
# Diff-Size: warnt bei zu grossen PRs
STAT=$(git diff --shortstat "origin/${{ github.base_ref }}..HEAD")
FILES=$(git diff --name-only "origin/${{ github.base_ref }}..HEAD" | wc -l)
ADDED=$(git diff --numstat "origin/${{ github.base_ref }}..HEAD" | awk '{s+=$1} END {print s+0}')
if [ "$ADDED" -gt 1000 ] || [ "$FILES" -gt 30 ]; then
  echo "status=warn" >> "$GITHUB_OUTPUT"
  echo "Diff: +${ADDED} Zeilen in ${FILES} Dateien"
else
  echo "status=pass" >> "$GITHUB_OUTPUT"
  echo "Diff +${ADDED} in ${FILES} Dateien"
fi
