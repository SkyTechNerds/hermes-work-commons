#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: automation-safety — HA-Automations-Fallen in PR-geänderten Zeilen.
#   1) State-Trigger mit `to:` aber ohne `from:`/`not_from:` → feuert beim HA-Neustart
#      (Entity geht unavailable→on, Trigger sieht nur das `to:`). Bekannter Live-Bug.
#   2) `device_id:` statt `entity_id:` (Projekt-Konvention: entity_id).
# Env: BASE_SHA, HEAD_SHA, DIFF_FILES. cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'automation-safety','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
YAML_FILES=$(echo "$DIFF_FILES" | grep -E '\.(ya?ml)$' || true)
[ -z "$YAML_FILES" ] && { emit skip "$(t "Keine YAML-Dateien im Diff" "No YAML files in the diff")"; exit 0; }

OUT="$(YAML_FILES="$YAML_FILES" BASE_SHA="$BASE_SHA" HEAD_SHA="$HEAD_SHA" python3 <<'PY'
import os, re, subprocess

base, head = os.environ["BASE_SHA"], os.environ["HEAD_SHA"]
findings = []

def added_lines(f):
    diff = subprocess.run(["git", "diff", "--unified=0", base, head, "--", f],
                          capture_output=True, text=True).stdout
    s = set()
    for m in re.finditer(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@', diff, re.M):
        start = int(m.group(1)); cnt = int(m.group(2) or 1)
        s.update(range(start, start + cnt))
    return s

def indent(line):
    return len(line) - len(line.lstrip(' '))

TRIGGER_RE = re.compile(r'^\s*-?\s*(platform|trigger):\s*[\'"]?state[\'"]?\s*(#.*)?$')

for f in os.environ["YAML_FILES"].split():
    if not os.path.isfile(f):
        continue
    changed = added_lines(f)
    if not changed:
        continue
    lines = open(f, encoding="utf-8", errors="replace").read().splitlines()

    # --- 1) from-lose State-Trigger: Listen-Item ab "- platform/trigger: state" bis
    #        zum nächsten Item auf gleicher/kleinerer Einrückung scannen.
    i = 0
    while i < len(lines):
        line = lines[i]
        if TRIGGER_RE.match(line):
            start = i
            # Einrückung des Item-Anfangs (des "-" falls vorhanden, sonst der Zeile)
            item_ind = indent(line)
            block = [(i + 1, line)]
            j = i + 1
            while j < len(lines):
                nxt = lines[j]
                if nxt.strip() == "" or nxt.lstrip().startswith("#"):
                    j += 1; continue
                ni = indent(nxt)
                # neues Listen-Item oder Dedent → Blockende
                if ni <= item_ind and (nxt.lstrip().startswith("-") or ni < item_ind):
                    break
                block.append((j + 1, nxt))
                j += 1
            text = "\n".join(b[1] for b in block)
            has_to = re.search(r'^\s*to:\s*\S', text, re.M)
            has_from = re.search(r'^\s*(from|not_from):\s*\S', text, re.M)
            touched = any(ln in changed for ln, _ in block)
            if has_to and not has_from and touched:
                L = os.environ.get("CODEMOLE_LANG", "de")
                if L == "en":
                    findings.append(f"{f}:{start + 1} state trigger with `to:` but no `from:` — fires on HA restart (unavailable→on). Add `from:`.")
                else:
                    findings.append(f"{f}:{start + 1} State-Trigger mit `to:` ohne `from:` — feuert beim HA-Neustart (unavailable→on). `from:` ergänzen.")
            i = j
        else:
            i += 1

    # --- 2) device_id in geänderten Zeilen
    for ln in sorted(changed):
        if ln <= len(lines) and re.match(r'^\s*-?\s*device_id:\s*\S', lines[ln - 1]) and not lines[ln - 1].lstrip().startswith("#"):
            if os.environ.get("CODEMOLE_LANG", "de") == "en":
                findings.append(f"{f}:{ln} `device_id:` instead of `entity_id:` — project convention: use entity_id (survives device replacement).")
            else:
                findings.append(f"{f}:{ln} `device_id:` statt `entity_id:` — Projekt-Konvention: entity_id verwenden (überlebt Geräte-Austausch).")

for x in findings:
    print(x)
PY
)"
if [ -z "$OUT" ]; then
  emit pass "$(t "Keine Trigger-/Konventions-Probleme in den geänderten Zeilen" "No trigger/convention issues in the changed lines")"
else
  N=$(echo "$OUT" | grep -c .)
  [ -n "${CM_INLINE:-}" ] && printf '%s\n' "$OUT" | CM_CHECK=automation-safety CM_SEV=warn python3 "$(dirname "${BASH_SOURCE[0]}")/../to-inline.py" >> "$CM_INLINE" 2>/dev/null
  emit warn "$(t "$N Trigger-/Konventions-Hinweis(e) — inline markiert" "$N trigger/convention hint(s) — flagged inline")"
fi
