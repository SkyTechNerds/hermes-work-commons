#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: php-lint — `php -l` (Syntax) auf geaenderten .php-Dateien. Zeigt den echten
# Fehler (datei:zeile Message) im Report + inline. Env: DIFF_FILES, CM_INLINE. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'php-lint','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v php >/dev/null 2>&1 || { emit skip "$(t "php nicht installiert" "php not installed")"; exit 0; }
mapfile -t PHP_FILES < <(printf '%s\n' "$DIFF_FILES" | grep -E '\.php$' || true)
[ "${#PHP_FILES[@]}" -eq 0 ] && { emit skip "$(t "Keine PHP-Dateien im Diff" "No PHP files in the diff")"; exit 0; }
ERRS=0; CHECKED=0; DETAIL=""; INLINE=""
for f in "${PHP_FILES[@]}"; do
  [ -f "$f" ] || continue
  CHECKED=$((CHECKED + 1))
  ERR="$(php -l "$f" 2>&1)" && continue
  ERRS=$((ERRS + 1))
  # php -l: "PHP Parse error:  syntax error, ... in FILE on line N"
  LN="$(printf '%s' "$ERR" | grep -oE 'on line [0-9]+' | head -1 | grep -oE '[0-9]+')"
  MSG="$(printf '%s' "$ERR" | grep -iE 'error' | head -1 | sed -E 's/ in .* on line [0-9]+//; s/^[[:space:]]*//')"
  DETAIL="${DETAIL}
${f}:${LN:-1}: ${MSG:-Parse error}"
  INLINE="${INLINE}
${f}:${LN:-1} ${MSG:-Parse error}"
done
[ "$CHECKED" -eq 0 ] && { emit skip "$(t "Nur geloeschte PHP-Dateien im Diff" "Only deleted PHP files in the diff")"; exit 0; }
if [ "$ERRS" -eq 0 ]; then
  emit pass "$(t "$CHECKED PHP-Datei(en) ohne Syntaxfehler" "$CHECKED PHP file(s) syntactically valid")"
else
  [ -n "${CM_INLINE:-}" ] && printf '%s\n' "$INLINE" | CM_CHECK=php-lint CM_SEV=error python3 "$D/to-inline.py" >> "$CM_INLINE" 2>/dev/null
  FULL="$(t "Syntaxfehler in $ERRS von $CHECKED PHP-Datei(en):" "Syntax errors in $ERRS of $CHECKED PHP file(s):")${DETAIL}"
  python3 -c "import json,sys;print(json.dumps({'name':'php-lint','status':'fail','message':sys.argv[1]}))" "$FULL"
fi
