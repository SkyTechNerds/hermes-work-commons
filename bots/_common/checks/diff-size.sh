#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: diff-size — Umfang des Diffs (konsistent auf den NICHT-ignorierten Dateien).
# Env: BASE_SHA, HEAD_SHA, DIFF_FILES, DIFF_FILES_FILE. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'diff-size','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
# git diff kennt kein --pathspec-from-file -> Datei-Liste als :(literal)-Pathspecs
# (kein Glob-/Magic-Parsing auf untrusted Dateinamen, Leerzeichen-sicher).
PATHSPEC=()
if [ -n "${DIFF_FILES_FILE:-}" ] && [ -s "${DIFF_FILES_FILE:-}" ]; then
  mapfile -t _PF < "$DIFF_FILES_FILE"
  PATHSPEC=(--)
  for _p in "${_PF[@]}"; do PATHSPEC+=(":(literal)$_p"); done
fi
STATS="$(git diff --numstat "$BASE_SHA" "$HEAD_SHA" "${PATHSPEC[@]}" | awk '{a+=$1; r+=$2} END {print a+0, r+0}')"
ADDED="${STATS%% *}"; REMOVED="${STATS##* }"
FILES=$(printf '%s\n' "$DIFF_FILES" | grep -c .)
if [ "$ADDED" -gt 1000 ] || [ "$FILES" -gt 30 ]; then ST=warn; PRE="$(t "Großer Diff: " "Large diff: ")"; else ST=pass; PRE="Diff "; fi
emit "$ST" "${PRE}+${ADDED}/-${REMOVED} $(t "in ${FILES} Dateien" "in ${FILES} files")"
