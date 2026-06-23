#!/bin/bash
# Code-Review: auto-generiert Review-Hints fuer neue Files / unbekannte Patterns
CHANGED=$(git diff --name-only "origin/${{ github.base_ref }}..HEAD")
NEW_FILES=$(echo "$CHANGED" | xargs git log --diff-filter=A --name-only --pretty=format: 2>/dev/null | sort -u)
if [ -z "$NEW_FILES" ]; then
  echo "status=skip" >> "$GITHUB_OUTPUT"
  echo "Keine neuen Dateien"
  exit 0
fi
echo "status=pass" >> "$GITHUB_OUTPUT"
echo "Neue Dateien: $(echo "$NEW_FILES" | wc -l) - manuelle Review empfohlen"
echo "$NEW_FILES" | head -5
