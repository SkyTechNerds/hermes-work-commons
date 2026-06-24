# hermes-work-commons

Geteilte Webhook-Discord-Action + Test-Logik für alle SkyTechNerds-Projekte.
**Die Action macht keine Tests.** Sie postet nur Discord-Messages.
Tests laufen auf unserem Server (LXC 113) vom Hermes-Bot.

## Architektur

```
┌────────────────────────────────────────────────────────────────┐
│ Kunden-Repo (z. B. JUMO-GmbH-Co-KG/JUMO-Website-CMS)          │
│                                                                │
│   .github/workflows/hermes-work.yml (~10 Zeilen)               │
│     → on: pull_request, issue_comment                          │
│     → uses: SkyTechNerds/hermes-work-commons@v2                │
│     → with: discord_webhook_url: ${{ secrets.DISCORD_... }}     │
└────────────────────────────┬───────────────────────────────────┘
                             │ Webhook-POST
                             ▼
┌────────────────────────────────────────────────────────────────┐
│ Discord (z. B. #qa-department)                                 │
│ Message: "PR_READY repo=JUMO-... pr=42 branch=wcms-..."        │
└────────────────────────────┬───────────────────────────────────┘
                             │ Hermes-Bot lauscht
                             ▼
┌────────────────────────────────────────────────────────────────┐
│ LXC 113 (192.168.2.81) — Hermes-Bot                           │
│                                                                │
│   bots/_common/discord-listener.js  - liest Messages           │
│   bots/_common/repo-resolver.js     - Repo → lokaler Pfad      │
│   bots/_common/comment-poster.js    - GitHub-API               │
│   bots/jumo/run.js                  - 9 JUMO-Checks            │
│   bots/ha/test-pr.sh                - 5 HA-Checks              │
│   ...                                                          │
│                                                                │
│ Führt Tests aus, postet Report zurück nach Discord + als       │
│ PR-Kommentar, macht Inline-Code-Review.                        │
└────────────────────────────────────────────────────────────────┘
```

## Repo-Struktur

```
hermes-work-commons/
├── action.yml                          # Webhook-Discord-POST (komplette Action)
├── README.md
├── LICENSE
├── examples/                           # Beispiel-Workflows für Kunden-Repos
│   ├── jumo-hermes-work.yml           # ~10 Zeilen für JUMO
│   └── ha-hermes-work.yml             # ~10 Zeilen für HA
└── bots/                               # Hermes-Bot-Code (läuft auf LXC 113)
    ├── _common/                        # gemeinsame Listener/Poster
    ├── jumo/                           # JUMO-spezifisch
    │   ├── run.js                      # 9 JUMO-Checks (Node)
    │   ├── build-block-deps.js         # AEM-Block-Dependency-Index
    │   ├── review-comment.sh           # Inline-Kommentar-Poster
    │   └── test-pr.sh                  # LXC-Wrapper
    └── ha/                             # HA-spezifisch
        ├── test-pr.sh                  # 5 HA-Checks (Bash)
        ├── render-report.py            # Report-Renderer
        ├── post-comment.py             # PR-Kommentar-Poster
        └── SETUP.md                    # HA-spezifische Doku
```

## Verwendung in einem neuen Repo

### 1) Workflow-Datei anlegen (10 Zeilen)

`.github/workflows/hermes-work.yml`:

```yaml
name: Notify Discord
on:
  pull_request:
    types: [opened, synchronize, edited]
  issue_comment:
    types: [created]
permissions:
  contents: read
jobs:
  notify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: SkyTechNerds/hermes-work-commons@v2
        with:
          discord_webhook_url: ${{ secrets.DISCORD_WEBHOOK_URL }}
```

### 2) Repo-Secret

`DISCORD_WEBHOOK_URL` = Webhook des Discord-Channels (z. B. `#qa-department`).

### 3) Hermes-Bot konfigurieren (auf LXC 113)

`bots/_common/repo-resolver.js` muss das neue Repo kennen:

```js
const REPOS = {
  'JUMO-GmbH-Co-KG/JUMO-Website-CMS': '/opt/jumo-cms',
  'SkyTechNerds/homeassistant-config': '/opt/ha-repo',
  'Deine-Org/Neues-Repo': '/opt/neues-repo-local',  // <- neu hinzufügen
};
```

Fertig. Die Action postet, der Bot resolved, führt die Tests aus, postet Report.

## Versionierung

- `@v2.3` — Minimal-Action: nur Webhook-POST (aktuell)
- `@v2.x` — frühere Versionen mit Test-Checks (überholt)
- `@v1` — erste Generation

## Bot-Deployment (LXC 113)

```bash
# Repo klonen:
git clone https://github.com/SkyTechNerds/hermes-work-commons.git /opt/hermes-work-commons

# Bot-Code symlinken:
ln -sf /opt/hermes-work-commons/bots/jumo /opt/jumo-testing
ln -sf /opt/hermes-work-commons/bots/ha /opt/ha-testing

# Bot neu starten (Discord-Listener):
systemctl restart hermes-bot
```

## Lizenz

Apache 2.0 — siehe LICENSE.