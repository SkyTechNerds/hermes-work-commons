#!/usr/bin/env python3
"""Postet einen HA-Test-Report als Kommentar auf den GitHub-PR."""
import json, sys, urllib.request, urllib.error

pr = sys.argv[1]
report_path = sys.argv[2]

with open("/opt/h...") as f:
    token = f.read().strip()
with open(report_path) as f:
    body = f.read()

req = urllib.request.Request(
    f"https://api.github.com/repos/SkyTechNerds/homeassistant-config/issues/{pr}/comments",
    data=json.dumps({"body": body}).encode(),
    headers={
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "hermes-work-ha",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        url = json.loads(resp.read()).get("html_url", "")
        print(f"POSTED: {url}")
except urllib.error.HTTPError as e:
    body = e.read().decode("utf-8", "replace")[:500]
    print(f"HTTP {e.code}: {body}")
    sys.exit(1)
