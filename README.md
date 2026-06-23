# hermes-work-commons

Shared PR-test suite for all SkyTechNerds repos.

Eine Composite GitHub Action mit dem Standard-9-Check-Set:
1. Secret-Scan
2. Diff-Size
3. Lint (yamllint / eslint / ruff — je nach Repo)
4. Path-Convention (projektspezifisch)
5. Review-Coverage (GitHub-API)
6. Test-Coverage (wenn Test-Framework vorhanden)
7. Visual-Snapshot (opt-in)
8. Code-Review (auto-generated beim Anlegen)
9. Changelog (wenn CHANGELOG.md existiert)

## Verwendung

In deinem Repo unter `.github/workflows/qa.yml`:

```yaml
name: QA
on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  qa:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: SkyTechNerds/hermes-work-commons@v1
        with:
          # Optionale Konfiguration:
          enable_visual_snapshot: false
          enable_code_review: true
          discord_webhook_secret: DISCORD_WEBHOOK_URL
```

## Konfiguration

Per `.hermes-work.yml` im Consumer-Repo:

```yaml
# Welche Linter-Tools nutzen?
linters:
  - yamllint
  # - eslint
  # - ruff

# Path-Convention: welche Dateien muessen wo liegen?
path_conventions:
  - pattern: "blocks/{name}/{name}.{js,css}"
    message: "Block-Files muessen unter blocks/<name>/<name>.{js,css} liegen"

# Discord-Mirror aktiv?
discord:
  channel_name: "ha-qa"
```

## Entwicklung

Lokal testen:

```bash
act pull_request -W .github/workflows/qa.yml  # benoetigt act
```

## Lizenz

Private — SkyTechNerds intern.
