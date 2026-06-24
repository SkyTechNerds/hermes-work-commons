# Hermes-Work Discord-Listener

Node.js Service der Discord-Channels pollt und `bots/<project>/test-pr.sh` triggert.

## Architektur

```
┌────────────────┐         ┌─────────────────┐         ┌──────────────────────┐
│ GitHub Action  │ webhook │ Discord Channel │ listen  │ discord-listener.js  │
│ in Kundenrepo  │────────▶│ #ha-qa,         │────────▶│ (Node.js, systemd)   │
└────────────────┘         │ #ha-soft-pres... │         └──────────┬───────────┘
                           └─────────────────┘                    │ spawn
                                                                  ▼
                          ┌──────────────────────────────────────────────────┐
                          │ bots/<project>/test-pr.sh <pr> <branch>          │
                          │  + gh api POST /repos/<repo>/issues/<pr>/comments │
                          └──────────────────────────────────────────────────┘
```

## Setup

### Voraussetzungen
- Node.js 18+ (auf LXC 113: v20.20.2 ✅)
- Discord-Bot mit Token in `/root/.config/discord-bot-token.txt` (chmod 600)
- GitHub-PAT in `/tmp/gh-token-raw.txt` (für PR-Kommentare)

### Schritt 1: Discord-Bot-Token beschaffen

1. https://discord.com/developers/applications → "New Application" → Name z.B. `hermes-work-bot`
2. Bot → "Add Bot" → Token kopieren (oder "Reset Token")
3. Bot zu deinen Channels einladen (OAuth2 → URL Generator → `bot` Scope → `Send Messages`, `Read Message History`, `Read Messages`)
4. Token in `/root/.config/discord-bot-token.txt` ablegen (chmod 600):
   ```bash
   echo "DEIN_BOT_TOKEN" > /root/.config/discord-bot-token.txt
   chmod 600 /root/.config/discord-bot-token.txt
   ```

### Schritt 2: Channel-Mapping konfigurieren

`discord-listener-config.json` editieren:
```json
{
  "channels": [
    {
      "id": "1519227518467575859",
      "name": "ha-soft-presence",
      "repo": "SkyTechNerds/ha-soft-presence",
      "project": "ha-soft-presence",
      "trigger_prefix": "TEST_REQUEST"
    }
  ]
}
```

JUMO-Channel (`qa-department`) hat einen Reviewer-Check im Workflow der PRs ohne passenden Reviewer überspringt — Listener reagiert nur auf Messages die durchkommen.

### Schritt 3: Service starten

```bash
# Einmalig: Token in BW hinterlegen damit Service ihn auch rotiert bekommt
# (aktuell: hardcoded path, manuell rotieren)

# Service aktivieren + starten
systemctl daemon-reload
systemctl enable hermes-discord-listener.service
systemctl start hermes-discord-listener.service

# Logs
journalctl -u hermes-discord-listener -f
```

### Schritt 4: Verifizieren

Im Discord-Channel schreiben:
```
!status
```
→ Bot antwortet mit Listener-Status.

Dann einen Test-PR öffnen → Webhook kommt rein → Bot startet automatisch Tests.

## Trigger-Syntax

Der Listener reagiert auf zwei Message-Typen:

### 1. TEST_REQUEST (vom GitHub-Action-Webhook)
Format: `TEST_REQUEST branch=<x> pr=<n> repo=<owner>/<repo>`
```
TEST_REQUEST branch=test/setup pr=14 repo=SkyTechNerds/ha-soft-presence
```
→ Listener ruft `bots/ha-soft-presence/test-pr.sh 14 test/setup main` auf
→ Postet Report als PR-Kommentar
→ Antwortet in Discord mit "✅ Tests done"

### 2. Commands (von Usern)
- `!retest` → re-runt den letzten Test-Request im Channel
- `!status` → Listener-Status

## File-Liste

| File | Zweck |
|------|-------|
| `discord-listener.js` | Node.js Service (~280 Zeilen) |
| `discord-listener-config.json` | Channel → Repo Mapping |
| `package.json` | npm dependencies (discord.js v14) |
| `node_modules/` | (gitignored) |
| `/etc/systemd/system/hermes-discord-listener.service` | systemd-unit |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Bot connected aber reagiert nicht | Channel-ID in Config prüfen |
| Token rotation | Token in `/root/.config/discord-bot-token.txt` ersetzen, `systemctl restart hermes-discord-listener` |
| Service startet nicht | `journalctl -u hermes-discord-listener -n 50` |
| Tests laufen, aber PR-Kommentar fehlt | GitHub-PAT in `/tmp/gh-token-raw.txt` prüfen |
| `PR_NOT_FOUND` Errors | PR-Nr im Discord-Footer prüfen, oder Repo-Renamed? |

## Sicherheit

- Discord-Bot-Token in `/root/.config/discord-bot-token.txt` (chmod 600)
- GitHub-PAT in `/tmp/gh-token-raw.txt` (für PR-Kommentar-Posts)
- Service läuft als root (nötig für `/opt/...`-Zugriff) — könnte auf dedizierten User gedownsized werden
- **NIEMALS** Tokens in Discord posten oder in Logs leakken

## Erweiterungen (geplant)

- Multi-Prefix Support (JUMO_TEST_REQUEST, TEST_REQUEST, PR_READY)
- Auto-retry bei transient failures
- Slack/Teams-Adapter für andere Plattformen
- Web-UI für Channel-Repo-Management