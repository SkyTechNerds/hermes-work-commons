#!/usr/bin/env python3
"""Postet einen Test-Report als Kommentar auf einen GitHub-PR — repo-generisch.

Ersetzt das alte /opt/ha-testing/post-comment.py (Repo war dort hardcodiert →
Reports anderer Repos landeten auf homeassistant-config).

- Token aus $GITHUB_TOKEN / $GH_TOKEN (App-Installation-Token oder PAT).
- Update-in-place: existiert schon ein Report-Kommentar (Marker), wird er per
  PATCH aktualisiert statt bei jedem synchronize-Push neu zu fluten.

Usage: post-comment.py <owner/repo> <pr> <report.md> [marker] [--update-only|--delete]

  marker         Optionaler HTML-Kommentar-Marker (Default: Report-Marker). So
                 lassen sich mehrere unabhaengige Kommentare (z.B. AI-Review-
                 Status) getrennt upserten.
  --update-only  Nur patchen, wenn schon ein Kommentar mit dem Marker existiert;
                 sonst NICHTS tun (kein Neu-Anlegen).
  --delete       Existierenden Marker-Kommentar loeschen (report.md wird ignoriert,
                 z.B. /dev/null uebergeben); no-op, wenn keiner existiert.
"""
import json
import os
import re
import sys
import urllib.request
import urllib.error

REPORT_MARKER = "<!-- hermes-work:report -->"
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
        raw = resp.read()
        return json.loads(raw) if raw else {}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if len(args) < 3:
        sys.exit("usage: post-comment.py <owner/repo> <pr> <report.md> [marker] [--update-only|--delete]")
    repo, pr, report_path = args[0], args[1], args[2]
    marker = args[3] if len(args) > 3 else REPORT_MARKER
    update_only = "--update-only" in flags
    delete = "--delete" in flags
    if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repo) or not pr.isdigit():
        sys.exit(f"ERROR: ungültige Argumente repo='{repo}' pr='{pr}'")

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        print("ERROR: GITHUB_TOKEN nicht gesetzt", file=sys.stderr)
        sys.exit(2)

    body = None
    if not delete:
        with open(report_path, encoding="utf-8") as f:
            body = f.read()
        if marker not in body:
            body = f"{marker}\n{body}"

    try:
        existing = gh("GET", f"/repos/{repo}/issues/{pr}/comments?per_page=100", token=token)
        prev = next((c for c in existing if marker in (c.get("body") or "")), None)
        if delete:
            if prev:
                gh("DELETE", f"/repos/{repo}/issues/comments/{prev['id']}", token=token)
                print(f"DELETED: comment {prev['id']}")
            else:
                print("NOOP: kein Kommentar mit Marker")
            return
        if prev:
            result = gh("PATCH", f"/repos/{repo}/issues/comments/{prev['id']}",
                        {"body": body}, token=token)
            print(f"UPDATED: {result.get('html_url', '?')}")
        elif update_only:
            print("NOOP: --update-only, kein bestehender Kommentar")
        else:
            result = gh("POST", f"/repos/{repo}/issues/{pr}/comments",
                        {"body": body}, token=token)
            print(f"POSTED: {result.get('html_url', '?')}")
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()[:500]}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
