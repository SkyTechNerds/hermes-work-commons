# ha-soft-presence Bot Setup

Custom-Component-Test-Runner für `SkyTechNerds/ha-soft-presence`.

## Was wird getestet?

| Check | Was | Wann fail |
|-------|-----|-----------|
| `python-syntax` | `python3 -m py_compile` auf alle geänderten `.py` | SyntaxError |
| `manifest` | Pflichtfelder in `manifest.json` | fehlt domain/name/version/etc |
| `hacs` | `hacs.json` mit `.name`-Feld | fehlt komplett |
| `translations` | Schlüssel-Konsistenz über alle Sprachen | Mismatch zu `en.json` |
| `secret-scan` | Klartext-Secrets im Diff | password/api_key/token im Diff |
| `diff-size` | Diff-Größe | >1500 Zeilen oder >40 Dateien |

**Bewusst NICHT getestet** (schon in `validate.yml` im Repo):
- HACS-Validation
- Hassfest
- Diese Checks laufen in GitHub Actions, doppelt wäre Verschwendung.

## Voraussetzungen im `ha-soft-presence` Repo

1. Secret `DISCORD_WEBHOOK_URL` zeigt auf Discord-Channel für ha-soft-presence (z. B. `#ha-soft-presence-qa`)
2. Workflow-Datei `.github/workflows/hermes-work.yml` (siehe `examples/ha-soft-presence-hermes-work.yml`)
3. Hermes-Bot auf LXC 113 muss `bots/ha-soft-presence/test-pr.sh` kennen

## Trigger-Mechanik

```
PR opened/sync/edited
  ↓
GitHub Action (hermes-work.yml) postet Webhook
  ↓
Discord: "TEST_REQUEST branch=<x> pr=<n> repo=SkyTechNerds/ha-soft-presence"
  ↓
Hermes-Bot liest Discord → resolved Repo → ruft bots/ha-soft-presence/test-pr.sh auf
  ↓
Bot cloned Repo, führt 6 Checks aus, postet Report als PR-Kommentar
```

## Manueller Re-Trigger

```bash
# Auf LXC 113:
/opt/hermes-work-commons/bots/ha-soft-presence/test-pr.sh <branch> <pr> main
```

## Files

- `test-pr.sh` — der Runner (chmod +x, ~6 KB)
- `SETUP.md` — diese Datei
- `../ha/` — Referenz-Implementation für HA-Config (nicht 1:1 kopierbar — andere Checks)

## Deployment

1. Diese Dateien in `hermes-work-commons` Repo committen + pushen (Branch `feature/ha-soft-presence-bot`)
2. Symlink auf LXC 113: `ln -sf /opt/hermes-work-commons/bots/ha-soft-presence /opt/ha-soft-presence-testing`
3. Workflow-Datei aus `examples/ha-soft-presence-hermes-work.yml` ins ha-soft-presence Repo legen + PR öffnen