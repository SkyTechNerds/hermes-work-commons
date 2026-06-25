# Hermes-Work Discord-Listener

Node.js Service der Discord-Channels pollt und `bots/<project>/test-pr.sh` triggert.

## Architektur

```text
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
- GitHub-PAT in `/root/.config/gh-token-raw.txt` (chmod 600, Service refused to start otherwise)

### Schritt 1: Discord-Bot-Token beschaffen

1. https://discord.com/developers/applications → "New Application" → Name z.B. `hermes-work-bot`
2. Bot → "Add Bot" → Token kopieren (oder "Reset Token")
3. Bot zu deinen Channels einladen (OAuth2 → URL Generator → `bot` Scope → `Send Messages`, `Read Message History`, `Read Messages`)
4. Token in `/root/.config/discord-bot-token.txt` ablegen (chmod 600):

    ```bash
    echo "DEIN_BOT_TOKEN" > /root/.config/discord-bot-token.txt
    chmod 600 /root/.config/discord-bot-token.txt
    ```

### Schritt 2: GitHub-PAT ablegen

Der Listener braucht einen GitHub-PAT um PR-Kommentare zu posten. Der Pfad muss `chmod 600` haben — der Service weigert sich sonst zu starten:

```bash
echo "ghp_DEIN_PAT" > /root/.config/gh-token-raw.txt
chmod 600 /root/.config/gh-token-raw.txt
```

### Schritt 3: Channel-Mapping konfigurieren

`discord-listener-config.json` editieren. Aktuelle Konfiguration (v1.1.0):

```json
{
  "version": "1.1.0",
  "channels": [
    {
      "id": "1483798451786350741",
      "name": "qa-department",
      "repo": "JUMO-GmbH-Co-KG/JUMO-Website-CMS",
      "project": "jumo",
      "trigger_prefix": "JUMO_TEST_REQUEST"
    },
    {
      "id": "1518915764478935170",
      "name": "ha-qa",
      "repo": "SkyTechNerds/homeassistant-config",
      "project": "ha",
      "trigger_prefix": "TEST_REQUEST"
    },
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

Projekt-Verzeichnis unter `BOTS_DIR` (= `/opt/hermes-work-commons/bots`) muss existieren, sonst Fehler "No test script".

### Schritt 4: Service starten

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

### Schritt 5: Verifizieren

Im Discord-Channel schreiben:

```text
!status
```

→ Bot antwortet mit Listener-Status.

Dann einen Test-PR öffnen → Webhook kommt rein → Bot startet automatisch Tests.

## Trigger-Syntax

Der Listener reagiert auf vier Message-Typen:

### 1. TEST_REQUEST / JUMO_TEST_REQUEST / PR_READY / PR_COMMENT (vom GitHub-Action-Webhook)

Format: `<TRIGGER> branch=<x> pr=<n>`

```text
TEST_REQUEST branch=test/setup pr=14 repo=SkyTechNerds/ha-soft-presence
```

→ Listener ruft `bots/ha-soft-presence/test-pr.sh 14 test/setup main` auf
→ Postet Report als PR-Kommentar
→ Antwortet in Discord mit "✅ Tests done"

Hinweis: das `repo=` Feld wird **ignoriert** wenn der Channel ein Mapping hat — das Repo kommt _immer_ aus `channelCfg.repo`. So können Channel-Mitglieder kein fremdes Repo targetieren.

### 2. Commands (von Usern)

- `!retest` → re-runt den letzten Test-Request im Channel
- `!status` → Listener-Status

## File-Liste

| File | Zweck |
|------|-------|
| `discord-listener.js` | Node.js Service (~340 Zeilen) |
| `discord-listener-config.json` | Channel → Repo Mapping |
| `package.json` | npm dependencies (discord.js v14) |
| `node_modules/` | (gitignored) |
| `/etc/systemd/system/hermes-discord-listener.service` | systemd-unit |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Bot connected aber reagiert nicht | Channel-ID in Config prüfen |
| Service startet nicht (FATAL gh token) | `chmod 600 /root/.config/gh-token-raw.txt` |
| Token rotation | Token in `/root/.config/discord-bot-token.txt` ersetzen, `systemctl restart hermes-discord-listener` |
| Service startet nicht | `journalctl -u hermes-discord-listener -n 50` |
| Tests laufen, aber PR-Kommentar fehlt | GitHub-PAT in `/root/.config/gh-token-raw.txt` prüfen — Listener meldet im Discord-Reply jetzt den HTTP-Status |
| `PR_NOT_FOUND` Errors | PR-Nr im Discord-Footer prüfen, oder Repo-Renamed? |
| `Wrong trigger for this channel` | `TEST_REQUEST` in einem Channel der `JUMO_TEST_REQUEST` erwartet (oder umgekehrt) |

## Sicherheit

- Discord-Bot-Token in `/root/.config/discord-bot-token.txt` (chmod 600)
- GitHub-PAT in `/root/.config/gh-token-raw.txt` (chmod 600, Service refused otherwise)
- Service läuft als root (nötig für `/opt/...`-Zugriff) — könnte auf dedizierten User gedownsized werden
- **NIEMALS** Tokens in Discord posten oder in Logs leakken
- Listener validiert Branch-Namen und PR-Nummern gegen Whitelist/Range bevor sie ein Shell-Skript erreichen
- Listener ignoriert `repo=` aus Discord-Messages und nutzt ausschließlich `channelCfg.repo`
- Test-Skript-Pfad wird via `realpath()` geprüft dass es unter `BOTS_DIR` liegt (Symlink-Escape-Schutz)

## Erweiterungen (geplant)

- Multi-Prefix Support ✅ (TEST_REQUEST, JUMO_TEST_REQUEST, PR_READY, PR_COMMENT)
- Auto-retry bei transient failures
- Slack/Teams-Adapter für andere Plattformen
- Web-UI für Channel-Repo-Management
- User-Whitelist (statt aktuell "alle Channel-Member dürfen triggern")
