# hermes-work-commons

Zentrales PR-Testing für **alle** SkyTechNerds-Repos. Eine Composite GitHub
Action mit dem Standard-Check-Set, plus projektspezifische Agent-Configs.

## Repo-Struktur

```
.
├── action.yml                          # Composite-Action-Definition
├── checks/                             # 8 Standard-Check-Skripte (Bash)
│   ├── secret-scan.sh
│   ├── diff-size.sh
│   ├── lint.sh
│   ├── aem-static-scans.sh             # AEM: Framework-Imports, outline:none
│   ├── visual-snapshot.sh              # 3-stufiges Spec-Matching
│   ├── path-convention.sh
│   ├── review-coverage.sh
│   └── code-review.sh
├── scripts/                            # Helper-Skripte
│   ├── post-report.sh                  # PR-Kommentar-Poster
│   ├── discord-mirror.sh               # Discord-Webhook
│   ├── build-block-deps.js             # AEM-Block-Dependency-Index
│   └── visual-transitive.js            # transitive Visual-Konsumenten
├── agents/                             # Projektspezifische Setups
│   ├── jumo/                           # JUMO-Website-CMS (AEM-EDS)
│   │   ├── README.md
│   │   ├── templates/
│   │   │   ├── hermes-work.yml         # → ins Kunden-Repo
│   │   │   └── .hermes-work.yml        # → optional ins Kunden-Repo
│   │   ├── inline-checks/
│   │   │   └── patterns.json           # AEM-Pattern (moveInstrumentation, XSS, …)
│   │   ├── run-inline-checks.js        # Diff → zeilengenaue Findings
│   │   └── test-fixtures/
│   │       └── bad-block.diff
│   └── ha/                             # [geplant] Home-Assistant
└── wiki/                               # Doku-Mirror (siehe /mnt/wiki)
```

## Standard-Check-Set (8 Checks)

| # | Check | Default |
|---|-------|---------|
| 1 | Secret-Scan | ✅ immer |
| 2 | Diff-Size | ✅ immer |
| 3 | Lint (ESLint/Stylelint/Ruff/yamllint) | ✅ immer |
| 4 | AEM-Static-Scans | opt-in |
| 5 | Visual-Snapshot (Playwright Spec-Match) | opt-in |
| 6 | Path-Convention | ✅ immer |
| 7 | Review-Coverage | ✅ immer |
| 8 | Code-Review (auto-hints) | ✅ immer |

## Verwendung

### Minimal (alle Repos)

In deinem Repo unter `.github/workflows/qa.yml`:

```yaml
name: QA
on:
  pull_request:
    types: [opened, synchronize, reopened]

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
          enable_code_review: 'true'
          discord_webhook_url: ${{ secrets.DISCORD_WEBHOOK_URL }}
```

### JUMO-spezifisch (AEM-EDS-Boilerplate)

Siehe `agents/jumo/templates/hermes-work.yml` — minimaler Wrapper mit
ESLint/Stylelint-Setup vor dem Action-Call. **Das ist die einzige Datei,
die ins Kunden-Repo `JUMO-GmbH-Co-KG/JUMO-Website-CMS` kopiert wird.**

### Home-Assistant (geplant)

Siehe `agents/ha/` — kommt wenn der HA-Workflow migriert wird.

## Konfiguration pro Consumer-Repo

Per `.hermes-work.yml` im Consumer-Repo (optional, mit sinnvollen Defaults):

```yaml
path_conventions:
  - pattern: "blocks/{name}/{name}.{js,css}"

aem:
  outline_none_exception: false

visual:
  spec_dirs: [visual-styleguide, test/visual]
  block_roots: [blocks, patterns/atoms, patterns/molecules, patterns/organisms]
```

## Agent-Workflow

`SkyTechNerds/hermes-work-commons` ist nicht nur eine Action, sondern auch
die Heimat für **alle** projektspezifischen Testing-Konfigurationen:

- Templates (was ins jeweilige Kunden-Repo kopiert wird)
- Inline-Check-Pattern (semantische Review-Hints, vom Hermes-Bot genutzt)
- Test-Fixtures und Runner-Helper

**Was NICHT in dieses Repo darf:**
- Kunden-Repo-Inhalte
- Geheimnisse (Token, Webhook-URLs)
- Build-Artefakte

## Versionierung

- `@v2.1` — Stable, Bug-Fixes
- `@v2` — Auto-Updates auf neueste v2.x (Standard)
- `@main` — Bleeding Edge

Major-Bumps (`v3`) nur bei Input-Namen-Änderung oder Output-Format-Bruch.

## Entwicklung

```bash
# Action lokal testen (im Consumer-Repo):
act pull_request -W .github/workflows/qa.yml  # benötigt act

# Inline-Check-Runner testen:
node agents/jumo/run-inline-checks.js agents/jumo/test-fixtures/bad-block.diff
```

## Lizenz

Apache 2.0 — siehe LICENSE.

## Wiki

Vollständige Doku: `/mnt/wiki/02_reference/handbooks/hermes-work-standards.md`
JUMO-spezifische Migration: `/mnt/wiki/02_reference/handbooks/jumo-work-onboarding.md`