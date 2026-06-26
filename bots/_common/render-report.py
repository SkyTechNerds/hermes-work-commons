#!/usr/bin/env python3
"""Gemeinsamer Report-Renderer für ALLE hermes-work Test-Bots.

Erzeugt das einheitliche hermes-work-Report-Format (Vorlage = JUMO run.js).
So sieht jeder Bot-Report identisch aus — neue Tests muessen NICHTS neu bauen.

TEMPLATE FUER NEUE TESTS:
  1. Im Test-Script die Checks als JSON sammeln:
       {"checks": [{"name": "...", "status": "pass|fail|warn|skip", "message": "..."}]}
  2. Diesen Renderer aufrufen:
       python3 .../_common/render-report.py <results.json> <branch> <base> <out.md>
  3. Die erzeugte <out.md> als PR-Kommentar posten (gh api / post-comment.py).

Format (identisch zu JUMO):
  ## 🧪 Automatischer PR-Test
  ✅ **Name** — Detail      (pass)
  ⚠️ **Name** — Detail      (warn)
  ❌ **Name** — Detail      (fail)
  ⚪ **Name** — ⏭️ Detail   (skip)
  ---  + ### <Name>\\n<Detail>  für Fails / mehrzeilige Details
  <sub>hermes-work · branch `x` · base `y`</sub>
"""
import json
import sys

ICON = {"pass": "✅", "fail": "❌", "warn": "⚠️", "skip": "⚪"}


def status_line(c):
    s = c.get("status", "pass")
    icon = ICON.get(s, "•")
    prefix = "⏭️ " if s == "skip" else ""
    first = (c.get("message") or "").split("\n")[0]
    return f"{icon} **{c['name']}** — {prefix}{first}"


def render(checks, branch="", base=""):
    lines = [status_line(c) for c in checks]
    body = "## 🧪 Automatischer PR-Test\n\n" + "\n".join(lines)
    details = [
        f"### {c['name']}\n{c['message']}"
        for c in checks
        if c.get("status") == "fail" or "\n" in (c.get("message") or "")
    ]
    if details:
        body += "\n\n---\n\n" + "\n\n".join(details)
    body += f"\n\n<sub>hermes-work · branch `{branch}` · base `{base}`</sub>"
    return body


def main():
    if len(sys.argv) < 5:
        sys.exit("usage: render-report.py <results.json> <branch> <base> <out.md>")
    results_file, branch, base, out_md = sys.argv[1:5]
    with open(results_file, encoding="utf-8") as f:
        data = json.load(f)
    body = render(data.get("checks", []), branch, base)
    with open(out_md, "w", encoding="utf-8") as f:
        f.write(body)
    print(body)


if __name__ == "__main__":
    main()
