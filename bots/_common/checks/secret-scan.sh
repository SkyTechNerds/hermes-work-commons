#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
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

ADDED="$(bash "$CM_COMMON/cm-file-diff.sh" "${_PF[@]}" | grep -E '^\+' | grep -vE '^\+\+\+' || true)"
[ -z "$ADDED" ] && { emit pass "$(t "Keine hinzugefügten Zeilen zu scannen" "No added lines to scan")"; exit 0; }

ASSIGN='(password|passwd|api_key|apikey|access_key|auth_token|token|secret|client_secret)[[:space:]]*[:=][[:space:]]*'
# Der Filter unten prueft die bestehende Wortliste irgendwo in der Zeile. Zusaetzlich
# braucht es Platzhalter, die als VOLLSTAENDIGER Wert stehen — allen voran das Wort
# "secret" selbst (`password: secret` in einer README ist ein Doku-Beispiel, kein Leak;
# faceid#16 wurde genau daran blockiert). Nur wenn der GANZE Wert so ein Wort ist,
# sonst wuerde "secret" im Wert ein echtes Fundstueck verstecken.
PLACEHOLDER_VAL='["'"'"']?(secret|password|passwd|geheim|hunter2|changeit|topsecret|mysecret|notreal|sample|demo|foobar)["'"'"']?[[:space:]]*$'
# quoted (>=6 Zeichen) oder unquoted (>=6 Zeichen); Templates/Referenzen/Platzhalter raus
HITS_ASSIGN="$(printf '%s\n' "$ADDED" \
  | grep -iE "${ASSIGN}([\"'][^\"'\$]{6,}[\"']|[A-Za-z0-9_/+=.-]{6,}([[:space:]]|\$))" \
  | grep -vE '^\+[[:space:]]*#' \
  | grep -viE '!secret|\$\{|\{\{|\{%|!env_var|<[A-Za-z_-]+>|(example|changeme|placeholder|redacted|dummy|xxxx|your[_-])' \
  | grep -viE "${ASSIGN}${PLACEHOLDER_VAL}" || true)"

HITS_KNOWN="$(printf '%s\n' "$ADDED" \
  | grep -E 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{22,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN ([A-Z]+ )?PRIVATE KEY|eyJ[A-Za-z0-9_-]{17,}\.eyJ[A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9]{32,}' \
  | grep -vE '^\+[[:space:]]*#' || true)"

N=$(( $(printf '%s' "$HITS_ASSIGN" | grep -c .) + $(printf '%s' "$HITS_KNOWN" | grep -c .) ))
if [ "$N" -eq 0 ]; then
  emit pass "$(t "Keine Klartext-Secrets in den hinzugefügten Zeilen" "No plaintext secrets in the added lines")"
else
  emit fail "$(t "$N mögliche Klartext-Secrets in hinzugefügten Zeilen" "$N possible plaintext secrets in added lines")"
fi
