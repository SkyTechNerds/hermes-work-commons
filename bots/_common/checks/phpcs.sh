#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: phpcs — WordPress-Security-Sniffs (Escaping, Nonces, Sanitization, SQL),
# ZWEI-PASS (nur neue/geaenderte Zeilen). Kein Stil-Rauschen — nur sicherheitsrelevant.
# Inline pro Fund, gedeckelt. Env: BASE_SHA, HEAD_SHA, DIFF_FILES, CM_INLINE. cwd=REPO_DIR.
# Ueberschreibbar: PHPCS_BIN, PHPCS_STANDARD, PHPCS_SNIFFS (leer = alle Sniffs des Standards).
emit() { python3 -c "import json,sys;print(json.dumps({'name':'phpcs','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
PHPCS="${PHPCS_BIN:-/root/.config/composer/vendor/bin/phpcs}"
[ -x "$PHPCS" ] || PHPCS="$(command -v phpcs 2>/dev/null)"
{ [ -n "$PHPCS" ] && [ -x "$PHPCS" ]; } || { emit skip "$(t "phpcs nicht installiert" "phpcs not installed")"; exit 0; }
mapfile -t PHP_FILES < <(printf '%s\n' "$DIFF_FILES" | grep -E '\.php$' || true)
[ "${#PHP_FILES[@]}" -eq 0 ] && { emit skip "$(t "Keine PHP-Dateien im Diff" "No PHP files in the diff")"; exit 0; }

# Default: nur Security-/SQL-relevante Sniffs (hohes Signal, kein Stil-Rauschen).
DEFAULT_SNIFFS="WordPress.Security.EscapeOutput,WordPress.Security.NonceVerification,WordPress.Security.ValidatedSanitizedInput,WordPress.Security.SafeRedirect,WordPress.Security.PluginMenuSlug,WordPress.DB.PreparedSQL,WordPress.DB.PreparedSQLPlaceholders"

PHPCS="$PHPCS" STANDARD="${PHPCS_STANDARD:-WordPress}" SNIFFS="${PHPCS_SNIFFS-$DEFAULT_SNIFFS}" \
BASE_SHA="${BASE_SHA:-}" HEAD_SHA="${HEAD_SHA:-}" CM_INLINE="${CM_INLINE:-}" CODEMOLE_LANG="${CODEMOLE_LANG:-de}" \
python3 - "${PHP_FILES[@]}" <<'PY'
import os, sys, re, json, subprocess
phpcs = os.environ["PHPCS"]; std = os.environ["STANDARD"]; sniffs = os.environ.get("SNIFFS", "")
base = os.environ.get("BASE_SHA", ""); head = os.environ.get("HEAD_SHA", "")
inline_path = os.environ.get("CM_INLINE", "")
de = os.environ.get("CODEMOLE_LANG", "de") != "en"
files = sys.argv[1:]
MAX_FILES = 30   # phpcs pro Datei ist teuer -> deckeln
MAX_FIND = 20    # Inline-Funde deckeln

def added_lines(f):
    """Im Diff NEU/geaenderte Zeilennummern (Zwei-Pass). None = nicht ermittelbar (fail-open)."""
    if not base or not head:
        return None
    try:
        out = subprocess.run(["git", "diff", "--unified=0", base, head, "--", f],
                             capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return None
    s = set()
    for m in re.finditer(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", out, re.M):
        start = int(m.group(1)); cnt = int(m.group(2) or 1)
        for ln in range(start, start + cnt):
            s.add(ln)
    return s

lint_files = files[:MAX_FILES]
capped = len(files) - len(lint_files)
findings = []; checked = 0
for f in lint_files:
    if not os.path.isfile(f):
        continue
    checked += 1
    add = added_lines(f)
    cmd = [phpcs, "--standard=" + std, "--report=json"]
    if sniffs:
        cmd.append("--sniffs=" + sniffs)
    cmd.append(f)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        data = json.loads(r.stdout or "{}")
    except Exception:
        continue
    for _fname, fd in (data.get("files") or {}).items():
        for msg in fd.get("messages", []):
            ln = msg.get("line", 0)
            if add is not None and ln not in add:
                continue  # Zwei-Pass: nur neue Zeilen
            findings.append((f, ln, f"[{msg.get('type','WARNING')}] {msg.get('message','').strip()}"))

if inline_path and findings:
    with open(inline_path, "a", encoding="utf-8") as out:
        for f, ln, msg in findings[:MAX_FIND]:
            out.write(json.dumps({"check": "phpcs", "file": f, "line": int(ln),
                                  "message": msg[:2000], "severity": "warn"}) + "\n")

n = len(findings); note = ""
if capped > 0:
    note = (f" ({capped} weitere Datei(en) nicht geprüft — Limit {MAX_FILES})" if de
            else f" ({capped} more file(s) skipped — limit {MAX_FILES})")
scope = "WPCS-Security" if sniffs else "WPCS"
if checked == 0:
    print(json.dumps({"name": "phpcs", "status": "skip",
                      "message": ("Nur gelöschte PHP-Dateien im Diff" if de else "Only deleted PHP files in the diff")}))
elif n == 0:
    print(json.dumps({"name": "phpcs", "status": "pass",
                      "message": ((f"{scope} sauber auf neuen Zeilen ({checked} Datei(en))" if de
                                   else f"{scope} clean on new lines ({checked} file(s))") + note)}))
else:
    shown = min(n, MAX_FIND)
    if de:
        m = f"{scope}: {n} Fund(e) auf neuen Zeilen in {checked} Datei(en) — {shown} inline markiert{note}"
    else:
        m = f"{scope}: {n} issue(s) on new lines in {checked} file(s) — {shown} flagged inline{note}"
    print(json.dumps({"name": "phpcs", "status": "warn", "message": m}))
PY
