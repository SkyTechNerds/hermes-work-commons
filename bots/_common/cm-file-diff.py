#!/usr/bin/env python3
"""Filtert einen unified Diff (stdin) auf die als argv uebergebenen Zieldateien
(Match auf die +++ b/<neuer-pfad>-Seite bzw. rename to). Ohne argv: kompletter Diff.
Dank `git diff -M` enthalten Rename-Bloecke nur die echten Aenderungszeilen, nicht
den ganzen verschobenen File."""
import sys, re
targets = set(a for a in sys.argv[1:] if a)
text = sys.stdin.read()
if not targets:
    sys.stdout.write(text); raise SystemExit(0)
out = []
for b in re.split(r"(?m)^(?=diff --git )", text):
    if not b.strip():
        continue
    m = re.search(r"(?m)^\+\+\+ b/(.+)$", b) or re.search(r"(?m)^rename to (.+)$", b)
    if m and m.group(1) in targets:
        out.append(b)
sys.stdout.write("".join(out))
