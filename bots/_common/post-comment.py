#!/usr/bin/env python3
"""Postet einen Test-Report als Kommentar auf einen GitHub-PR — repo-generisch.

Ersetzt das alte /opt/ha-testing/post-comment.py (Repo war dort hardcodiert →
Reports anderer Repos landeten auf homeassistant-config).

- Token aus $GITHUB_TOKEN / $GH_TOKEN (App-Installation-Token oder PAT).
- Update-in-place: existiert schon ein Report-Kommentar (Marker), wird er per
  PATCH aktualisiert statt bei jedem synchronize-Push neu zu fluten.

Usage: post-comment.py <owner/repo> <pr> <report.md>
"""
import json
import os
import re
import sys
import urllib.request
import urllib.error

MARKER = "<!-- hermes-work:report -->"
API = "https://api.github.com"


def gh(method, path, data=None, token=None):
    req = urllib.request.Request(
        f"{API}{path}",
        data=json.dumps(data).encode() if data is not None else None,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "hermes-work",
        },
        method=method,
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def main():
    if len(sys.argv) < 4:
        sys.exit("usage: post-comment.py <owner/repo> <pr> <report.md>")
    repo, pr, report_path = sys.argv[1], sys.argv[2], sys.argv[3]
    if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repo) or not pr.isdigit():
        sys.exit(f"ERROR: ungültige Argumente repo='{repo}' pr='{pr}'")

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        print("ERROR: GITHUB_TOKEN nicht gesetzt", file=sys.stderr)
        sys.exit(2)

    with open(report_path, encoding="utf-8") as f:
        body = f.read()
    if MARKER not in body:
        body = f"{MARKER}\n{body}"

    try:
        existing = gh("GET", f"/repos/{repo}/issues/{pr}/comments?per_page=100", token=token)
        prev = next((c for c in existing if MARKER in (c.get("body") or "")), None)
        if prev:
            result = gh("PATCH", f"/repos/{repo}/issues/comments/{prev['id']}",
                        {"body": body}, token=token)
            print(f"UPDATED: {result.get('html_url', '?')}")
        else:
            result = gh("POST", f"/repos/{repo}/issues/{pr}/comments",
                        {"body": body}, token=token)
            print(f"POSTED: {result.get('html_url', '?')}")
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()[:500]}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
