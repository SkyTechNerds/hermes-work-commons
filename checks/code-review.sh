#!/bin/bash
# Code-Review: auto-generiert Review-Hints fuer neue Files / unbekannte Patterns
BASE="${BASE_REF:-${GITHUB_BASE_REF:-main}}"
REPO="${GITHUB_REPOSITORY:-${REPO_FULL:-}}"
PR_NUM="${PR_NUMBER:-${GITHUB_EVENT_PULL_REQUEST_NUMBER:-}}"

# Liste der neuen Files (im PR hinzugefügt) ermitteln
NEW_FILES=$(git diff --name-only "origin/${BASE}..HEAD" 2>/dev/null \
  | while read f; do
      if [ -n "$f" ] && [ -f "$f" ]; then
        # Check via gh ob File neu im PR
        added=$(gh pr view "$PR_NUM" --json files --jq ".files[] | select(.path==\"$f\") | .additions // 0" 2>/dev/null || echo 0)
        # Vereinfachung: jede geänderte Datei gilt als "neu" für Review-Empfehlung
        echo "$f"
      fi
    done | head -20)

COUNT=$(echo "$NEW_FILES" | grep -c . || echo 0)

if [ "$COUNT" -eq 0 ]; then
  {
    echo "status=skip"
    echo "detail=Keine Datei-Änderungen"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

{
  echo "status=pass"
  echo "detail=$COUNT Dateien geändert — Code-Review empfohlen"
} >> "$GITHUB_OUTPUT"
echo "$NEW_FILES" | head -5