#!/usr/bin/env python3
"""diff-locate.py '<regex>' [--label TEXT | --content]

Liest einen `git diff --unified=0` von stdin und gibt für jede HINZUGEFÜGTE Zeile,
die auf <regex> passt, "datei:zeile" aus (für die CM_INLINE-Sammlung).
  --label TEXT : hängt TEXT als Meldung an  -> "datei:zeile TEXT"
  --content    : hängt den Zeileninhalt an  -> "datei:zeile <code>"
Ohne beides nur "datei:zeile". Regex wird gegen den Zeileninhalt (ohne '+') geprüft.
"""
import sys, re

args = sys.argv[1:]
rx = re.compile(args[0]) if args and not args[0].startswith("--") else None
label = ""
if "--label" in args:
    i = args.index("--label")
    label = args[i + 1] if i + 1 < len(args) else ""
want_content = "--content" in args

cur = None
line = 0
for raw in sys.stdin:
    if raw.startswith("+++ "):
        m = re.match(r"\+\+\+ b/(.*)", raw.rstrip("\n"))
        cur = m.group(1) if m else None
    elif raw.startswith("@@"):
        m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", raw)
        if m:
            line = int(m.group(1)) - 1
    elif raw.startswith("+") and not raw.startswith("+++"):
        line += 1
        code = raw[1:].rstrip("\n")
        if cur and (rx is None or rx.search(code)):
            suffix = f" {label}" if label else (f" {code.strip()}" if want_content else "")
            print(f"{cur}:{line}{suffix}")
