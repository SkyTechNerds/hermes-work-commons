#!/usr/bin/env python3
"""post-inline-findings.py <findings.jsonl> <owner/repo> <pr>

Postet strukturierte Check-Funde als ZEILENGENAUE Inline-Review-Kommentare —
mit Dedup (jeder Fund trägt einen versteckten Marker <!-- cm-inline:check:file:line -->;
existiert er schon, wird nicht erneut gepostet → kein Spam bei jedem Push/synchronize).
Zeilen, die nicht im Diff-Hunk liegen (GitHub 422), werden still übersprungen.

findings.jsonl: eine JSON-Zeile pro Fund: {"check","file","line","message","severity"}
Token via GH_TOKEN/GITHUB_TOKEN (App-Installation-Token bevorzugt).
"""
import sys, os, re, json, urllib.request, urllib.error

if len(sys.argv) < 4:
    print("usage: post-inline-findings.py <findings.jsonl> <repo> <pr>"); sys.exit(2)
FINDINGS, REPO, PR = sys.argv[1], sys.argv[2], sys.argv[3]
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
if not TOKEN:
    print("post-inline: kein Token"); sys.exit(0)


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request("https://api.github.com" + path, data=data, method=method,
        headers={"Authorization": "Bearer " + TOKEN, "Accept": "application/vnd.github+json",
                 "User-Agent": "codemole-inline", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.load(e)
        except Exception:
            return e.code, {}
    except Exception:
        return 0, {}


findings = []
try:
    for ln in open(FINDINGS, encoding="utf-8"):
        ln = ln.strip()
        if ln:
            try:
                findings.append(json.loads(ln))
            except Exception:
                pass
except FileNotFoundError:
    pass
if not findings:
    print("INLINE: keine Funde"); sys.exit(0)

st, pr = api("GET", f"/repos/{REPO}/pulls/{PR}")
sha = (pr or {}).get("head", {}).get("sha")
if not sha:
    print("INLINE: kein head-SHA"); sys.exit(0)

# bereits gepostete Inline-Marker sammeln (Dedup)
existing = set()
page = 1
while page <= 5:
    st, cs = api("GET", f"/repos/{REPO}/pulls/{PR}/comments?per_page=100&page={page}")
    if not isinstance(cs, list) or not cs:
        break
    for c in cs:
        for m in re.findall(r"<!-- (cm-inline:[^>]+?) -->", c.get("body") or ""):
            existing.add(m.strip())
    if len(cs) < 100:
        break
    page += 1

posted = dup = nodiff = fail = 0
for f in findings:
    check, path, line = f.get("check", "check"), f.get("file"), f.get("line")
    msg, sev = f.get("message", ""), f.get("severity", "warn")
    if not path or not line:
        continue
    key = f"cm-inline:{check}:{path}:{line}"
    if key in existing:
        dup += 1; continue
    icon = "⚠️ " if sev in ("warn", "fail", "major") else ""
    body = f"{icon}{msg}\n\n<sub>CodeMole · `{check}`</sub>\n<!-- {key} -->"
    st, _ = api("POST", f"/repos/{REPO}/pulls/{PR}/comments",
                {"body": body, "commit_id": sha, "path": path, "line": int(line), "side": "RIGHT"})
    if st in (200, 201):
        posted += 1; existing.add(key)
    elif st == 422:
        nodiff += 1
    else:
        fail += 1
print(f"INLINE: {posted} gepostet, {dup} schon vorhanden, {nodiff} nicht im Diff, {fail} Fehler")
