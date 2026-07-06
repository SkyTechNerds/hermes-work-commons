#!/usr/bin/env python3
"""to-inline.py — wandelt Check-Fundzeilen "datei:zeile[:spalte] text" in Inline-JSONL.
Liest stdin (eine Fundzeile pro Zeile), schreibt eine JSON-Zeile pro Fund nach stdout
(für die CM_INLINE-Sammeldatei). Env: CM_CHECK (Check-Name), CM_SEV (severity, default warn)."""
import sys, os, re, json

check = os.environ.get("CM_CHECK", "check")
sev = os.environ.get("CM_SEV", "warn")
for ln in sys.stdin:
    ln = ln.rstrip("\n")
    if not ln.strip():
        continue
    m = re.match(r'^(\S+?):(\d+)(?::\d+)?\s+(.*)$', ln)
    if not m:
        continue
    print(json.dumps({"check": check, "file": m.group(1), "line": int(m.group(2)),
                      "message": m.group(3), "severity": sev}))
