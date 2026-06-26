#!/usr/bin/env python3
"""hermes-work — yamllint nur auf den im PR GEÄNDERTEN Zeilen, mit HA-tauglichen Regeln.

HA-Config-Dateien (automations.yaml etc.) verletzen die yamllint-Defaults massenhaft
(line-length, truthy on/off, comments, document-start) — das ganze File zu linten ergibt
tausende Vorbestand-Fehler, die nichts mit dem PR zu tun haben. Dieser Helfer lintet die
geänderten Dateien, behält aber nur Findings auf den durch den PR hinzugefügten Zeilen.

Usage: yamllint-diff.py <base_sha> <head_sha> <file1> [file2 ...]
Gibt gefilterte yamllint-parsable-Zeilen aus (leer = sauber). Exit 0.
"""
import subprocess, sys, re, tempfile, os

RELAXED = """extends: default
rules:
  line-length: disable
  truthy: disable
  comments: disable
  comments-indentation: disable
  document-start: disable
  empty-lines: disable
  indentation: disable
  brackets: disable
  braces: disable
  hyphens: disable
  new-line-at-end-of-file: disable
  trailing-spaces: enable
  key-duplicates: enable
"""


def added_lines(base, head, f):
    diff = subprocess.run(["git", "diff", "--unified=0", base, head, "--", f],
                          capture_output=True, text=True).stdout
    s = set()
    for m in re.finditer(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@', diff, re.M):
        start = int(m.group(1)); cnt = int(m.group(2) or 1)
        s.update(range(start, start + cnt))
    return s


def main():
    if len(sys.argv) < 4:
        return
    base, head, files = sys.argv[1], sys.argv[2], sys.argv[3:]
    with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as tf:
        tf.write(RELAXED); conf = tf.name
    out = []
    try:
        for f in files:
            al = added_lines(base, head, f)
            if not al:
                continue
            lint = subprocess.run(["yamllint", "-c", conf, "-f", "parsable", f],
                                  capture_output=True, text=True).stdout
            for line in lint.splitlines():
                m = re.match(r'^.+?:(\d+):\d+:', line)
                if m and int(m.group(1)) in al:
                    out.append(line)
    finally:
        os.unlink(conf)
    sys.stdout.write("\n".join(out))


main()
