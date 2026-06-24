#!/usr/bin/env python3
"""Rendert einen HA-Test-Report als Markdown-Comment."""
import json, sys, pathlib

results_file, pr, branch, base = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = json.loads(pathlib.Path(results_file).read_text())
checks = data["checks"]

# Status-Icons (Discord rendert die direkt)
icon = {"pass": "✅", "fail": "❌", "warn": "⚠️", "skip": "⏭️"}
counts = {"pass": 0, "fail": 0, "warn": 0, "skip": 0}
for c in checks:
    counts[c["status"]] = counts.get(c["status"], 0) + 1

total = len(checks)
all_pass = counts["fail"] == 0 and counts["warn"] == 0

lines = []
lines.append(f"## 🤖 HA-Config QA Report — PR #{pr}")
lines.append("")
lines.append(f"**Branch:** `{branch}` → `{base}`  ·  **Checks:** {total}")
lines.append("")
lines.append("| Status | Check | Message |")
lines.append("|--------|-------|---------|")
for c in checks:
    i = icon.get(c["status"], "❔")
    msg = c["message"].replace("|", "\\|")
    lines.append(f"| {i} | **{c['name']}** | {msg} |")
lines.append("")
lines.append(f"**Summary:** {counts['pass']} pass · {counts['fail']} fail · {counts['warn']} warn · {counts['skip']} skip")
if all_pass:
    lines.append("")
    lines.append("✅ **All checks green.**")
else:
    lines.append("")
    lines.append("⚠️ **Action required** — see failed checks above.")

pathlib.Path(f"/tmp/ha-report-{pr}.md").write_text("\n".join(lines))
print(f"WROTE /tmp/ha-report-{pr}.md ({len(lines)} lines)")