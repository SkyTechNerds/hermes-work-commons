#!/bin/bash
# Check-Modul: secret-scan — Klartext-Secrets in NEU HINZUGEFÜGTEN Zeilen.
# Env: BASE_SHA, HEAD_SHA, DIFF_FILES_FILE (optional, für ignore). cwd=REPO_DIR.
#
# Scannt nur '+'-Zeilen (ein PR, der ein Secret ENTFERNT, darf nicht failen) und
# respektiert die ignore-Globs (via DIFF_FILES_FILE-Pathspec). Zwei Pattern-Klassen:
#   1. Zuweisungen: password/api_key/token/secret mit ':' oder '=' — quoted UND unquoted
#   2. Bekannte Token-Formate: GitHub-PATs, AWS-Keys, Slack, private Keys, JWTs
emit() { python3 -c "import json,sys;print(json.dumps({'name':'secret-scan','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }

# git diff kennt kein --pathspec-from-file -> Datei-Liste als :(literal)-Pathspecs
# (kein Glob-/Magic-Parsing auf untrusted Dateinamen, Leerzeichen-sicher).
PATHSPEC=()
if [ -n "${DIFF_FILES_FILE:-}" ] && [ -s "${DIFF_FILES_FILE:-}" ]; then
  mapfile -t _PF < "$DIFF_FILES_FILE"
  PATHSPEC=(--)
  for _p in "${_PF[@]}"; do PATHSPEC+=(":(literal)$_p"); done
fi

ADDED="$(git diff --unified=0 "$BASE_SHA" "$HEAD_SHA" "${PATHSPEC[@]}" | grep -E '^\+' | grep -vE '^\+\+\+' || true)"
[ -z "$ADDED" ] && { emit pass "Keine hinzugefügten Zeilen zu scannen"; exit 0; }

ASSIGN='(password|passwd|api_key|apikey|access_key|auth_token|token|secret|client_secret)[[:space:]]*[:=][[:space:]]*'
# quoted (>=6 Zeichen) oder unquoted (>=6 Zeichen); Templates/Referenzen/Platzhalter raus
HITS_ASSIGN="$(printf '%s\n' "$ADDED" \
  | grep -iE "${ASSIGN}([\"'][^\"'\$]{6,}[\"']|[A-Za-z0-9_/+=.-]{6,}([[:space:]]|\$))" \
  | grep -vE '^\+[[:space:]]*#' \
  | grep -viE '!secret|\$\{|\{\{|\{%|!env_var|<[A-Za-z_-]+>|(example|changeme|placeholder|redacted|dummy|xxxx|your[_-])' || true)"

HITS_KNOWN="$(printf '%s\n' "$ADDED" \
  | grep -E 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{22,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN ([A-Z]+ )?PRIVATE KEY|eyJ[A-Za-z0-9_-]{17,}\.eyJ[A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9]{32,}' \
  | grep -vE '^\+[[:space:]]*#' || true)"

N=$(( $(printf '%s' "$HITS_ASSIGN" | grep -c .) + $(printf '%s' "$HITS_KNOWN" | grep -c .) ))
if [ "$N" -eq 0 ]; then
  emit pass "Keine Klartext-Secrets in den hinzugefügten Zeilen"
else
  emit fail "$N mögliche Klartext-Secrets in hinzugefügten Zeilen"
fi
