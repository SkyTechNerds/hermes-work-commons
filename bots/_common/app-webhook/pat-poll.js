#!/usr/bin/env node
'use strict';
/**
 * pat-poll.js — Event-Ersatz fuer Owner OHNE GitHub-App-Installation (z.B. JUMO).
 *
 * Die App kann dort nicht installiert werden -> es kommen KEINE Webhooks an.
 * Dieser Poller holt den Zustand per PAT ab und speist exakt dieselben Events
 * LOKAL in den Handler (127.0.0.1:3956), den auch GitHub schicken wuerde:
 *
 *   - pull_request              -> voller Lauf (Checks + ai-review + Approve)
 *   - pull_request_review_comment -> ai-reply (Antwort auf Finding-Threads)
 *   - issue_comment             -> Mention-Q&A / `recheck`
 *
 * Damit hat ein PAT-Owner denselben Funktionsumfang wie ein App-Owner.
 *
 * Konfiguration (alle chmod 600, ausserhalb des Repos):
 *   /etc/hermes-work-app/pat-owners.json  { "<owner>": "<pfad-zur-token-datei>" }
 *   /etc/hermes-work-app/pat-repos.json   { "<owner>": ["owner/repo", ...] }
 * State: /var/lib/hermes-work-app/pat-poll-state.json
 *
 * Cron alle 3 min (flock). Idempotent: bereits eingespeiste Kommentar-IDs werden
 * gemerkt, PR-Laeufe nur bei fehlendem/veraltetem Report.
 */
const https = require('https'), http = require('http'), crypto = require('crypto'), fs = require('fs'), path = require('path');

const CONF_DIR = process.env.HERMES_APP_CONF || '/etc/hermes-work-app';
const STATE_DIR = process.env.HERMES_APP_STATE || '/var/lib/hermes-work-app';
const STATE_FILE = path.join(STATE_DIR, 'pat-poll-state.json');
const SEC = fs.readFileSync(path.join(CONF_DIR, 'webhook-secret'), 'utf8').trim();
const GRACE_MS = 120 * 1000;   // Report darf 2 min hinter dem Head liegen
const FRESH_MS = 90 * 1000;    // ganz frischer Head -> noch nicht anfassen
const SEEN_KEEP = 300;         // wieviele Kommentar-IDs je Repo gemerkt werden

const log = m => console.log(new Date().toISOString(), m);

function readJson(p, fallback) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return fallback; }
}

function api(apiPath, token) {
  return new Promise((res, rej) => {
    const rq = https.request({ host: 'api.github.com', path: apiPath, method: 'GET',
      headers: { 'User-Agent': 'hermes-pat-poll', Accept: 'application/vnd.github+json',
        Authorization: 'token ' + token, 'X-GitHub-Api-Version': '2022-11-28' } },
      x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { try { res(JSON.parse(d || '{}')); } catch (e) { rej(e); } }); });
    rq.on('error', rej); rq.end();
  });
}

// --dry-run: nur zeigen, WAS eingespeist wuerde (nichts posten). Zum Pruefen,
// bevor der Poller das erste Mal auf fremde/Kunden-PRs losgelassen wird.
const DRY_RUN = process.argv.includes('--dry-run');
// Auto-Approve fuer PAT-Owner ist bewusst OPT-IN (PAT_POLL_APPROVE=1). Grund:
// im PAT-Modus approved kein neutraler Bot-Account, sondern der PAT-Inhaber
// persoenlich — auf einem fremden/Kunden-Repo ist das eine Aussage mit Gewicht.
// Ohne den Schalter laufen Checks, Review, Replies und Mentions trotzdem.
const DO_APPROVE = process.env.PAT_POLL_APPROVE === '1';
const { spawn } = require('child_process');
const BOTS_DIR = process.env.HERMES_BOTS_DIR || '/opt/hermes-work-commons/bots';

// `pr-approve.sh auto` bewertet selbst (offene Bot-Threads + ❌ im Report).
// Noetig, weil ein PAT-Owner den Approve sonst NIE bekaeme: der Push-Pfad laeuft
// hier nur, wenn der Poller einen Lauf einspeist — bei aktuellem Report tut er das
// nicht, und dann faende auch nie eine Neubewertung statt.
function approveAuto(repo, pr, tokenPath) {
  return new Promise(res => {
    if (DRY_RUN) return res('DRY');
    const fsx = require('fs');
    let tk = ''; try { tk = fsx.readFileSync(tokenPath, 'utf8').trim(); } catch { return res('no-token'); }
    const p = spawn('bash', [path.join(BOTS_DIR, '_common', 'pr-approve.sh'), repo, String(pr), 'auto'],
      { env: { ...process.env, GH_TOKEN: tk, GITHUB_TOKEN: tk }, timeout: 120000 });
    let out = '';
    p.stdout.on('data', d => out += d); p.stderr.on('data', d => out += d);
    p.on('close', () => res(out.trim().replace(/\n/g, ' | ').slice(-200)));
    p.on('error', e => res('spawn-fail: ' + e.message));
  });
}

// Signiertes Event lokal in den Handler geben (umgeht Cloudflare/Webhook komplett).
function inject(event, payload, deliveryId) {
  if (DRY_RUN) return Promise.resolve('DRY');
  return new Promise(res => {
    const body = JSON.stringify(payload);
    const sig = 'sha256=' + crypto.createHmac('sha256', SEC).update(body).digest('hex');
    const rq = http.request({ host: '127.0.0.1', port: 3956, path: '/webhook', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-GitHub-Event': event,
        'X-Hub-Signature-256': sig, 'X-GitHub-Delivery': deliveryId,
        'Content-Length': Buffer.byteLength(body) } },
      x => { x.on('data', () => {}); x.on('end', () => res(x.statusCode)); });
    rq.on('error', () => res(-1)); rq.write(body); rq.end();
  });
}

// Bot-eigene Texte tragen einen unsichtbaren HTML-Marker. Im PAT-Modus teilen sich
// Bot und Mensch EINEN Account — nach Login zu filtern wuerde deshalb auch die echten
// Kommentare des Menschen verwerfen (er koennte den Bot nie ansprechen).
const BOT_MARK_RE = /<!--\s*(codemole:bot|hermes-work:(report|ai-status)|cm-inline:)/i;

const numFromUrl = u => { const m = /\/(\d+)$/.exec(u || ''); return m ? parseInt(m[1], 10) : null; };

(async () => {
  const owners = readJson(path.join(CONF_DIR, 'pat-owners.json'), {});
  const repoMap = readJson(path.join(CONF_DIR, 'pat-repos.json'), {});
  const state = readJson(STATE_FILE, { repos: {} });
  if (!state.repos) state.repos = {};
  let injected = 0, checked = 0;

  for (const [owner, tokenPath] of Object.entries(owners)) {
    let token;
    try { token = fs.readFileSync(tokenPath, 'utf8').trim(); } catch { log(`kein Token fuer ${owner} (${tokenPath})`); continue; }
    const repos = repoMap[owner] || [];
    if (!repos.length) { log(`${owner}: keine Repos in pat-repos.json`); continue; }

    for (const repo of repos) {
      const st = state.repos[repo] || (state.repos[repo] = { since: null, seen: [] });
      const seen = new Set(st.seen || []);
      const nowIso = new Date().toISOString();

      // --- 1) Kommentare -------------------------------------------------
      // Erster Lauf setzt nur die Marke: KEIN Backfill (sonst wuerde der Bot
      // auf jeden alten Kommentar der Repo-Historie antworten).
      if (!st.since) {
        st.since = nowIso;
        log(`${repo}: erste Beobachtung — Startmarke gesetzt (kein Backfill)`);
      } else {
        const since = encodeURIComponent(st.since);
        // Review-Kommentare = Antworten auf Inline-Findings -> ai-reply
        const rc = await api(`/repos/${repo}/pulls/comments?since=${since}&sort=created&direction=asc&per_page=100`, token);
        for (const c of (Array.isArray(rc) ? rc : [])) {
          if (seen.has('r' + c.id)) continue;
          seen.add('r' + c.id);
          if (BOT_MARK_RE.test(c.body || '')) continue;             // eigener Text (Marker) -> Loop-Schutz
          if (!c.in_reply_to_id) continue;                          // nur Thread-Antworten
          const pr = numFromUrl(c.pull_request_url);
          if (!pr) continue;
          const code = await inject('pull_request_review_comment', {
            action: 'created', comment: c,
            pull_request: { number: pr },
            repository: { full_name: repo },
          }, `patpoll-rc-${c.id}`);
          log(`inject review_comment ${repo}#${pr} (comment ${c.id}) -> HTTP ${code}`);
          injected++;
        }
        // Top-Level-Kommentare: nur mit Mention (alles andere waere Rauschen)
        const ic = await api(`/repos/${repo}/issues/comments?since=${since}&sort=created&direction=asc&per_page=100`, token);
        for (const c of (Array.isArray(ic) ? ic : [])) {
          if (seen.has('i' + c.id)) continue;
          seen.add('i' + c.id);
          if (BOT_MARK_RE.test(c.body || '')) continue;             // eigener Text (Marker)
          if (!/@(the-)?codemole/i.test(c.body || '')) continue;
          const nr = numFromUrl(c.issue_url);
          if (!nr) continue;
          const code = await inject('issue_comment', {
            action: 'created', comment: c,
            issue: { number: nr, pull_request: { url: c.issue_url } },
            repository: { full_name: repo },
          }, `patpoll-ic-${c.id}`);
          log(`inject issue_comment ${repo}#${nr} (comment ${c.id}) -> HTTP ${code}`);
          injected++;
        }
        st.since = nowIso;
      }
      st.seen = Array.from(seen).slice(-SEEN_KEEP);

      // --- 2) PRs ohne aktuellen Report ----------------------------------
      const pulls = await api(`/repos/${repo}/pulls?state=open&per_page=50`, token);
      for (const pr of (Array.isArray(pulls) ? pulls : [])) {
        if (pr.draft) continue;
        checked++;
        const head = pr.head.sha;
        const commit = await api(`/repos/${repo}/commits/${head}`, token);
        const headTime = new Date((commit.commit && commit.commit.committer && commit.commit.committer.date) || pr.updated_at).getTime();
        if (Date.now() - headTime < FRESH_MS) continue;
        const comments = await api(`/repos/${repo}/issues/${pr.number}/comments?per_page=100`, token);
        const reports = (Array.isArray(comments) ? comments : []).filter(c => /hermes-work:report/.test(c.body || ''));
        const last = reports[reports.length - 1];
        if (last && headTime <= new Date(last.updated_at).getTime() + GRACE_MS) {
          // Report ist aktuell -> kein Doppel-Lauf. Nur die Approve-Frage neu stellen
          // (Findings koennen zwischenzeitlich per Reply/Resolve erledigt worden sein).
          if (DO_APPROVE) {
            const r = await approveAuto(repo, pr.number, tokenPath);
            if (!/APPROVE-SKIP|DISMISS-NOOP/.test(r)) log(`approve ${repo}#${pr.number}: ${r}`);
          }
          continue;
        }
        const code = await inject('pull_request', {
          action: 'synchronize', number: pr.number,
          pull_request: { number: pr.number, state: pr.state, draft: pr.draft, merged: pr.merged || false,
            head: { ref: pr.head.ref, sha: head }, base: { ref: pr.base.ref } },
          repository: { full_name: repo },
        }, `patpoll-pr-${pr.number}-${head.slice(0, 8)}`);
        log(`inject pull_request ${repo}#${pr.number} (head ${head.slice(0, 8)}, ${last ? 'Report veraltet' : 'kein Report'}) -> HTTP ${code}`);
        injected++;
      }
    }
  }

  if (DRY_RUN) {
    log('DRY-RUN: State NICHT geschrieben, nichts gepostet.');
  } else try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 1));
  } catch (e) { log('state-write-fail: ' + e.message); }
  log(`pat-poll fertig: ${checked} offene PRs geprueft, ${injected} Events eingespeist`);
})().catch(e => log('pat-poll-error: ' + e.message));
