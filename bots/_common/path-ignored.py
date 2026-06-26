#!/usr/bin/env python3
"""path-ignored.py — filtert Pfade gegen die ignore-Globs aus dem Resolver.

Liest Pfade von stdin (1 pro Zeile), liest die Globs aus $RESOLVE (JSON, Feld "ignore"),
gibt nur die NICHT-ignorierten Pfade aus. Keine Globs / kein $RESOLVE -> alles durch.
Glob-Semantik: '*' matcht auch '/', '**/' wird normalisiert (für vendor/**, **/*.x).
"""
import sys
import os
import json
import fnmatch

try:
    globs = json.loads(os.environ.get("RESOLVE", "{}")).get("ignore") or []
except Exception:
    globs = []


def ignored(p):
    for g in globs:
        g2 = g.replace("**/", "").replace("**", "*")
        if fnmatch.fnmatch(p, g) or fnmatch.fnmatch(p, g2) or fnmatch.fnmatch(p, "*/" + g2):
            return True
    return False


for line in sys.stdin:
    p = line.rstrip("\n")
    if p and not ignored(p):
        print(p)
