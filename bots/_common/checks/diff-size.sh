#!/bin/bash
# Check-Modul: diff-size — Umfang des Diffs. Env: BASE_SHA, HEAD_SHA, DIFF_FILES. cwd=REPO_DIR.
ADDED=$(git diff --numstat "$BASE_SHA" "$HEAD_SHA" | awk '{s+=$1} END {print s+0}')
REMOVED=$(git diff --numstat "$BASE_SHA" "$HEAD_SHA" | awk '{s+=$2} END {print s+0}')
FILES=$(echo "$DIFF_FILES" | grep -c .)
if [ "$ADDED" -gt 1000 ] || [ "$FILES" -gt 30 ]; then ST=warn; PRE="Grosser Diff: "; else ST=pass; PRE="Diff "; fi
python3 -c "import json;print(json.dumps({'name':'diff-size','status':'$ST','message':'${PRE}+${ADDED}/-${REMOVED} in ${FILES} Dateien'}))"
