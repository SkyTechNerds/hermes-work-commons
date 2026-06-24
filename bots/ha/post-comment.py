#!/usr/bin/env python3
"""Postet einen HA-Test-Report als Kommentar auf den GitHub-PR.

Token wird aus $GITHUB_TOKEN env gelesen (vom Bot-Wrapper gesetzt via
bots/_common/load-token.sh). Frühere Versionen lasen /opt/ha-testing/.token,
das ist obsolet.
"""
import json, os, sys, urllib.request, urllib.error

pr = sys.argv[1]
report_path = sys.argv[2]

token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
if not token:
    print("ERROR: GITHUB_TOKEN nicht gesetzt", file=sys.stderr)
    sys.exit(2)

with open(report_path) as f:
    body = f.read()

req = urllib.request.Request(
    f"https://api.github.com/repos/SkyTechNerds/homeassistant-config/issues/{pr}/comments",
    data=json.dumps({"body": body}).encode(),
    headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "hermes-work-ha",
    },
    method="POST",
)

try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        result = json.loads(resp.read())
        print(f"POSTED: {result.get('html_url', '?')}")
except urllib.error.HTTPError as e:
    print(f"HTTP {e.code}: {e.read().decode()[:500]}", file=sys.stderr)
    sys.exit(1)
