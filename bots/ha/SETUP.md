# Anleitung: hermes-work HA-Config QA einrichten

Diese Anleitung beschreibt, wie du den hermes-work QA-Workflow
für `SkyTechNerds/homeassistant-config` Schritt für Schritt
einrichtest und mit einem Test-PR verifizierst.

## Voraussetzungen

- Lokaler Clone von `https://github.com/SkyTechNerds/homeassistant-config`
- Schreibrechte auf das Repo (oder einen Fork, auf dem du Admin bist)
- GitHub CLI (`gh`) ist optional aber hilfreich
- Im Discord existiert bereits ein privater Channel `#ha-qa`
  (ID `1518915764478935170`)
- Im `#ha-qa`-Channel existiert ein Webhook, dessen URL als
  **Repository-Secret** `DISCORD_WEBHOOK_URL` hinterlegt ist

Falls das Secret noch nicht existiert, prüfe:
- Repo → Settings → Secrets and variables → Actions → Secrets
- Secret-Name muss exakt `DISCORD_WEBHOOK_URL` lauten (case-sensitive)

## Schritt 1 — Workflow-Datei anlegen

Lege im Repo die Datei `.github/workflows/ha-config-qa.yml` an
mit folgendem Inhalt:

```yaml
name: HA-Config QA
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
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq yamllint jq

      - name: Fetch PR head
        run: |
          git fetch --depth=1 origin "${{ github.head_ref }}"
          git checkout --quiet FETCH_HEAD

      - name: Run YAML-Lint
        id: yamllint
        run: |
          CHANGED=$(git diff --name-only "origin/${{ github.base_ref }}..HEAD" | grep -E '\.(ya?ml)$' || true)
          if [ -z "$CHANGED" ]; then
            echo "status=skip" >> "$GITHUB_OUTPUT"
            echo "Keine YAML-Dateien im Diff" >> "$GITHUB_STEP_SUMMARY"
          else
            OUT=$(yamllint -f parsable $CHANGED 2>&1 || true)
            if [ -z "$OUT" ]; then
              echo "status=pass" >> "$GITHUB_OUTPUT"
              echo "✅ yamllint: $(echo "$CHANGED" | wc -l) YAML-Dateien sauber" >> "$GITHUB_STEP_SUMMARY"
            else
              echo "status=fail" >> "$GITHUB_OUTPUT"
              echo "❌ yamllint:" >> "$GITHUB_STEP_SUMMARY"
              echo '```' >> "$GITHUB_STEP_SUMMARY"
              echo "$OUT" | head -20 >> "$GITHUB_STEP_SUMMARY"
              echo '```' >> "$GITHUB_STEP_SUMMARY"
            fi
          fi

      - name: Secret-Scan
        id: secrets
        run: |
          HITS_FILE=$(mktemp)
          git diff "origin/${{ github.base_ref }}..HEAD" \
            | grep -iE 'password[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{6,}|api_key[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{8,}|token[[:space:]]*:[[:space:]]*["\x27][^"\x27$]{8,}' \
            | grep -vE '^[-+][[:space:]]*#|!secret' > "$HITS_FILE" || true
          HITS=$(cat "$HITS_FILE")
          if [ -z "$HITS" ]; then
            echo "status=pass" >> "$GITHUB_OUTPUT"
            echo "✅ secret-scan: keine Klartext-Secrets" >> "$GITHUB_STEP_SUMMARY"
          else
            echo "status=fail" >> "$GITHUB_OUTPUT"
            echo "❌ secret-scan: $(echo "$HITS" | wc -l) Verdachtsfälle" >> "$GITHUB_STEP_SUMMARY"
            echo '```' >> "$GITHUB_STEP_SUMMARY"
            echo "$HITS" | head -10 >> "$GITHUB_STEP_SUMMARY"
            echo '```' >> "$GITHUB_STEP_SUMMARY"
          fi

      - name: Diff-Size
        id: diff
        run: |
          STAT=$(git diff --shortstat "origin/${{ github.base_ref }}..HEAD")
          FILES=$(git diff --name-only "origin/${{ github.base_ref }}..HEAD" | wc -l)
          ADDED=$(git diff --numstat "origin/${{ github.base_ref }}..HEAD" | awk '{s+=$1} END {print s+0}')
          echo "status=pass" >> "$GITHUB_OUTPUT"
          echo "✅ diff-size: $STAT ($FILES Dateien)" >> "$GITHUB_STEP_SUMMARY"

      - name: Includes-Check
        id: includes
        run: |
          REFS_FILE=$(mktemp)
          git diff "origin/${{ github.base_ref }}..HEAD" \
            | grep -oE '![[:space:]]*include[[:space:]]+[^\n]*\.ya?ml' \
            | sed -E 's/^![[:space:]]*include[[:space:]]+//;s/^["\x27]//;s/["\x27]$//' \
            | sort -u > "$REFS_FILE" || true
          REFS=$(cat "$REFS_FILE")
          if [ -z "$REFS" ]; then
            echo "status=skip" >> "$GITHUB_OUTPUT"
            echo "⏭️ includes: keine im Diff" >> "$GITHUB_STEP_SUMMARY"
          else
            MISSING=""
            for ref in $REFS; do
              [ ! -f "$ref" ] && MISSING="$MISSING $ref"
            done
            if [ -n "$MISSING" ]; then
              echo "status=fail" >> "$GITHUB_OUTPUT"
              echo "❌ includes: fehlend:$MISSING" >> "$GITHUB_STEP_SUMMARY"
            else
              echo "status=pass" >> "$GITHUB_OUTPUT"
              echo "✅ includes: alle auflösbar" >> "$GITHUB_STEP_SUMMARY"
            fi
          fi

      - name: Mirror to Discord
        if: always()
        env:
          DISCORD_WEBHOOK_URL: ${{ secrets.DISCORD_WEBHOOK_URL }}
        run: |
          if [ -z "$DISCORD_WEBHOOK_URL" ]; then
            echo "No DISCORD_WEBHOOK_URL secret set - skipping Discord mirror"
            exit 0
          fi
          YL='${{ steps.yamllint.outputs.status }}'
          SC='${{ steps.secrets.outputs.status }}'
          DS='${{ steps.diff.outputs.status }}'
          INC='${{ steps.includes.outputs.status }}'
          ICON_PASS='✅'
          ICON_FAIL='❌'
          ICON_SKIP='⏭️'
          ICON_WARN='⚠️'
          ICON() { case "$1" in pass) echo "$ICON_PASS";; fail) echo "$ICON_FAIL";; warn) echo "$ICON_WARN";; *) echo "$ICON_SKIP";; esac; }
          SUMMARY="**PR #${{ github.event.pull_request.number }}** — $(ICON $YL) yamllint · $(ICON $SC) secret-scan · $(ICON $DS) diff-size · $(ICON $INC) includes"
          PAYLOAD=$(jq -n --arg c "🤖 HA-Config QA Report\n${SUMMARY}\n<https://github.com/${{ github.repository }}/pull/${{ github.event.pull_request.number }}|View PR>" '{content: $c}')
          curl -fsS -H "Content-Type: application/json" -d "$PAYLOAD" "$DISCORD_WEBHOOK_URL"

      - name: Post QA Report
        if: always()
        uses: actions/github-script@v7
        with:
          script: |
            const yl = '${{ steps.yamllint.outputs.status }}' || 'skip';
            const sc = '${{ steps.secrets.outputs.status }}' || 'skip';
            const ds = '${{ steps.diff.outputs.status }}' || 'skip';
            const inc = '${{ steps.includes.outputs.status }}' || 'skip';
            const icon = {pass:'✅', fail:'❌', warn:'⚠️', skip:'⏭️'};
            const allGreen = [yl,sc,ds,inc].every(s => s === 'pass' || s === 'skip');
            const body = [
              '## 🤖 HA-Config QA Report — PR #' + context.issue.number,
              '',
              '| Status | Check |',
              '|--------|-------|',
              `| ${icon[yl]||'❔'} | **yamllint** |`,
              `| ${icon[sc]||'❔'} | **secret-scan** |`,
              `| ${icon[ds]||'❔'} | **diff-size** |`,
              `| ${icon[inc]||'❔'} | **includes** |`,
              '',
              allGreen ? '✅ **All checks green.**' : '⚠️ **Action required** — see failed checks.'
            ].join('\n');
            await github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body
            });
```

## Schritt 2 — Workflow committen und pushen

```bash
cd /path/to/SkyTechNerds/homeassistant-config
mkdir -p .github/workflows
# Datei anlegen (Inhalt oben)
git add .github/workflows/ha-config-qa.yml
git commit -m "ci: add hermes-work HA-Config QA workflow"
git push origin main
```

## Schritt 3 — Dummy-PR erzeugen

```bash
git checkout -b qa-test-dummy
# Kleine Änderung in einer beliebigen YAML-Datei machen:
echo "# test-comment von hermes-work smoke-test" >> configuration.yaml
git add configuration.yaml
git commit -m "test: trigger hermes-work QA smoke-test"
git push origin qa-test-dummy
```

Dann auf GitHub einen Pull Request öffnen:
- Base: `main`
- Compare: `qa-test-dummy`

## Schritt 4 — Erwartete Ergebnisse

Nach PR-Öffnung laufen die Checks automatisch. Erwartung:

1. **GitHub PR-Kommentar** mit Titel
   `🤖 HA-Config QA Report — PR #XX` und Status-Tabelle
2. **Discord-Nachricht** im Channel `#ha-qa`:

   ```
   🤖 HA-Config QA Report
   **PR #XX** — ✅ yamllint · ✅ secret-scan · ✅ diff-size · ⏭️ includes
   <View PR>
   ```

3. **GitHub Actions Run** mit fünf Steps:
   - Run YAML-Lint
   - Secret-Scan
   - Diff-Size
   - Includes-Check
   - Mirror to Discord
   - Post QA Report

## Schritt 5 — Aufräumen nach dem Test

Nach erfolgreichem Test den Test-Branch und PR wieder löschen:

```bash
# lokal:
git checkout main
git branch -D qa-test-dummy
git push origin --delete qa-test-dummy

# PR auf GitHub schließen
```

## Fehlerbehebung

### Workflow startet nicht
- Prüfe, ob die YAML-Datei in `.github/workflows/` liegt (nicht
  versehentlich in einem Unterordner)
- Prüfe, ob der Branch-Name `main` ist (oder passe `base: main` im
  Workflow an)

### Kein Discord-Mirror
- Prüfe, ob das Secret exakt `DISCORD_WEBHOOK_URL` heißt
  (case-sensitive)
- Prüfe Actions-Log auf den Step „Mirror to Discord" — dort steht
  entweder `No DISCORD_WEBHOOK_URL secret set - skipping Discord
  mirror` oder ein `curl`-Fehler
- Teste den Webhook manuell:
  ```bash
  curl -X POST -H "Content-Type: application/json" \
    -d '{"content":"smoke-test"}' \
    "<WEBHOOK-URL>"
  ```

### Kein PR-Kommentar
- Prüfe den `permissions:`-Block im Workflow —
  `pull-requests: write` muss gesetzt sein
- Prüfe Actions-Log auf den Step „Post QA Report" — Fehler stehen
  dort

### Yamllint-Fehler im Workflow selbst
Der Workflow ist bewusst lang (>80 Zeichen pro Zeile), das ist OK.
GitHub Actions ignoriert das. Falls dein Repo eine strikte
yamllint-Konfig hat, lege `.yamllint` mit `line-length: disable`
im Repo-Wurzelverzeichnis an.

## Optional: Workflow erweitern

### Weitere Checks hinzufügen
Siehe Wiki-Eintrag
`02_reference/handbooks/handbook-hermes-work-onboarding.md`
unter „Neue Check-Stufe hinzufügen".

### Discord-Message-Format anpassen
Im Step „Mirror to Discord" den `SUMMARY`-String ändern, z. B.
um Repository-Name oder Commit-SHA ergänzen.

## Lokale Tests (ohne PR)

Falls du den Workflow vor dem Commit testen willst, kannst du die
Checks lokal ausführen:

```bash
# Im Repo-Wurzelverzeichnis:
sudo apt-get install -y yamllint jq
git fetch origin main
git checkout origin/main

BASE_SHA=origin/main
HEAD_SHA=HEAD
DIFF=$(git diff --name-only $BASE_SHA $HEAD_SHA | grep -E '\.(ya?ml)$')

if [ -z "$DIFF" ]; then
  echo "Keine YAML-Änderungen"
else
  yamllint -f parsable $DIFF
fi
```

## Quelle

Workflow-Vorlage liegt auf dem Hermes-LXC unter
`/opt/ha-testing/workflow-ha-test.yml` (mit `.bak-before-discord`
als Backup vor Discord-Mirror-Erweiterung).