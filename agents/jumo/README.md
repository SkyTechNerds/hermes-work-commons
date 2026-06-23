# jumo-testing-agent

JUMO-spezifische Test-Konfiguration, Workflow-Templates und Inline-Check-Logik
für `JUMO-GmbH-Co-KG/JUMO-Website-CMS` (AEM Edge Delivery Services).

## Was ist hier drin?

| Pfad | Inhalt | Wohin damit |
|---|---|---|
| `templates/hermes-work.yml` | Minimale 15-Zeilen-Wrapper-Workflow | → ins **Kunden-Repo** unter `.github/workflows/hermes-work.yml` |
| `templates/.hermes-work.yml` | JUMO-Path- + AEM-Konfiguration | → optional ins Kunden-Repo, oder als Config in diesem Repo referenziert |
| `examples/block-deps.json` | AEM-Block-Dependency-Index (gebaut von der Action) | wird automatisch generiert, hier nur Beispiel |
| `docs/` | Mirror der relevanten Wiki-Sektionen | — |
| `inline-checks/` | Pattern-Definitionen für semantische Hermes-Bot-Inline-Kommentare (moveInstrumentation, XSS, etc.) | bleibt hier, der Hermes-Bot liest von hier |

## Was NICHT hier rein darf

- **Niemals** Push auf `JUMO-GmbH-Co-KG/JUMO-Website-CMS` (Kunden-Repo).
  Nur die zwei Template-Dateien werden **manuell** von dir in den jeweiligen
  Kunden-Repo kopiert.
- Keine Geheimnisse (Token, Webhook-URLs). Alles über GitHub-Secrets im
  jeweiligen Kunden-Repo.

## Quickstart: JUMO-Repo anbinden

### 1. Workflow-Datei ins Kunden-Repo

In `JUMO-GmbH-Co-KG/JUMO-Website-CMS` einmalig anlegen
unter `.github/workflows/hermes-work.yml`:

```yaml
# Vollständiger Inhalt siehe templates/hermes-work.yml
name: Hermes-Work QA
on:
  pull_request:
    types: [opened, synchronize, reopened, edited]
permissions:
  contents: read
  pull-requests: write
jobs:
  qa:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: SkyTechNerds/hermes-work-commons@v2
        with:
          enable_aem_static_scans: 'true'
          enable_visual_snapshot: 'true'
          discord_webhook_url: ${{ secrets.DISCORD_WEBHOOK_URL }}
```

Das ist **alles** was im Kunden-Repo landet.

### 2. Repo-Secret

Im Kunden-Repo unter Settings → Secrets:
- `DISCORD_WEBHOOK_URL` = Webhook aus dem `#qa-department`-Channel

### 3. (Optional) `.hermes-work.yml` ins Kunden-Repo

Wenn du Path-Conventions pro Kunden-Repo individuell willst.
Sonst nutzt die Action ihre Defaults.

## Versionierung

Tag `v1` zeigt auf den aktuellen stabilen Stand der Templates.
`main`-Branch ist bleeding edge.

## Lizenz

Apache 2.0 — siehe LICENSE.