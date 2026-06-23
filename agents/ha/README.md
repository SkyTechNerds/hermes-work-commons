# Home-Assistant Testing-Agent (geplant)

Sobald der HA-Workflow auf `hermes-work-commons` migriert wird, kommen die
HA-spezifischen Sachen hier hin.

## Geplant

- `templates/hermes-work.yml` — minimaler Wrapper für HA
- `templates/.hermes-work.yml` — HA-Path- + Lint-Konvention
- `inline-checks/patterns.json` — HA-spezifische Patterns
  (z. B. `!secret` in Configuration, fehlende `unique_id`, etc.)
- `run-inline-checks.js` — gemeinsam genutzt mit JUMO-Agent
- `test-fixtures/` — Beispiele

## Stand

Noch leer. Migration läuft sobald der HA-Workflow-Push durch ist.