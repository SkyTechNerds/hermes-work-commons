#!/bin/bash
# cm-file-diff.sh [file...] — rename-bewusster unified=0 Diff: git -M ueber den GANZEN
# Diff, dann auf die uebergebenen Dateien gefiltert. Ersetzt die pro-Datei/PATHSPEC-
# Diffs der Checks, die bei Renames die ganze verschobene Datei als "added" zaehlten
# (pathspec bricht Git-Rename-Detection). Env: BASE_SHA, HEAD_SHA. cwd=REPO_DIR.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
git diff --unified=0 -M "$BASE_SHA" "$HEAD_SHA" | python3 "$D/cm-file-diff.py" "$@"
