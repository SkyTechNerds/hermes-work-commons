#!/usr/bin/env node
'use strict';
/**
 * catchup.js — Catch-up-Sweep fuer verpasste Webhook-Deliveries.
 *
 * GitHub gibt bei Zustell-Timeout (Internet-Blip, Cloudflare 5xx) nach EINEM Versuch
 * auf → ein PR bleibt still ungeprueft. Dieser Sweep findet offene PRs der App-
 * Installationen ohne AKTUELLEN CodeMole-Report und speist sie LOKAL in den Handler
 * (127.0.0.1:3956) — unabhaengig von der externen Cloudflare-Stabilitaet.
 *
 * Cron alle 10 min (flock-gesichert). Idempotent: run-checks nutzt flock, Report wird
 * ge-updatet, Inline dedupt. Der In-Flight-Guard verhindert vorzeitige Approves.
 */
const https = require('https'), http = require('http'), crypto = require('crypto'), fs = require('fs');

const APP_ID = '4150723';
const KEY = fs.readFileSync('/etc/hermes-work-app/private-key.pem', 'utf8');
const SEC = fs.readFileSync('/etc/hermes-work-app/webhook-secret', 'utf8').trim();
const ALLOWED_OWNERS = ['SkyTechNerds', 'JUMO-GmbH-Co-KG', 'schimanski-antegma'];
const GRACE_MS = 120 * 1000;  // Report muss <=2min vor Head liegen, sonst gilt PR als offen
const FRESH_MS = 90 * 1000;   // Head juenger als 90s -> normaler Webhook noch unterwegs, nicht racen

const log = m => console.log(new Date().toISOString(), m);

function appJwt() {
  const now = Math.floor(Date.now() / 1000);
  const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
  const p = b64({ alg: 'RS256', typ: 'JWT' }) + '.' + b64({ iat: now - 60, exp: now + 540, iss: APP_ID });
  return p + '.' + crypto.sign('RSA-SHA256', Buffer.from(p), KEY).toString('base64url');
}

function api(path, token, method = 'GET') {
  return new Promise((res, rej) => {
    const auth = token.startsWith('ey') ? 'Bearer ' + token : 'token ' + token;
    const rq = https.request({ host: 'api.github.com', path, method,
      headers: { 'User-Agent': 'hermes-catchup', Accept: 'application/vnd.github+json', Authorization: auth } },
      x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { try { res(JSON.parse(d || '{}')); } catch (e) { rej(e); } }); });
    rq.on('error', rej); rq.end();
  });
}

function inject(repo, pr, instId, head) {
  return new Promise(res => {
    const payload = JSON.stringify({
      action: 'synchronize', number: pr.number,
      pull_request: { number: pr.number, state: pr.state, draft: pr.draft, merged: pr.merged || false,
        head: { ref: pr.head.ref, sha: head }, base: { ref: pr.base.ref } },
      repository: { full_name: repo }, installation: { id: instId },
    });
    const sig = 'sha256=' + crypto.createHmac('sha256', SEC).update(payload).digest('hex');
    const rq = http.request({ host: '127.0.0.1', port: 3956, path: '/webhook', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-GitHub-Event': 'pull_request',
        'X-Hub-Signature-256': sig, 'X-GitHub-Delivery': 'catchup-' + pr.number } },
      x => { let d = ''; x.on('data', c => d += c); x.on('end', () => res(x.statusCode)); });
    rq.on('error', () => res(-1)); rq.write(payload); rq.end();
  });
}

(async () => {
  const jwt = appJwt();
  const insts = await api('/app/installations', jwt);
  if (!Array.isArray(insts)) { log('keine Installationen: ' + JSON.stringify(insts).slice(0, 150)); return; }
  let checked = 0, injected = 0;
  for (const inst of insts) {
    if (!inst.account || !ALLOWED_OWNERS.includes(inst.account.login)) continue;
    const tokRes = await api('/app/installations/' + inst.id + '/access_tokens', jwt, 'POST');
    const tok = tokRes.token;
    if (!tok) continue;
    const reposResp = await api('/installation/repositories?per_page=100', tok);
    const repos = (reposResp.repositories || []).map(r => r.full_name);
    for (const repo of repos) {
      const pulls = await api('/repos/' + repo + '/pulls?state=open&per_page=50', tok);
      if (!Array.isArray(pulls)) continue;
      for (const pr of pulls) {
        if (pr.draft) continue;
        checked++;
        const head = pr.head.sha;
        const commit = await api('/repos/' + repo + '/commits/' + head, tok);
        const headTime = new Date((commit.commit && commit.commit.committer && commit.commit.committer.date) || pr.updated_at).getTime();
        if (Date.now() - headTime < FRESH_MS) continue;  // ganz frisch -> Webhook noch unterwegs
        const comments = await api('/repos/' + repo + '/issues/' + pr.number + '/comments?per_page=100', tok);
        const reports = (Array.isArray(comments) ? comments : [])
          .filter(c => c.user && /the-codemole/.test(c.user.login) && /hermes-work:report/.test(c.body || ''));
        const last = reports[reports.length - 1];
        const needs = !last || (headTime > new Date(last.updated_at).getTime() + GRACE_MS);
        if (needs) {
          const code = await inject(repo, pr, inst.id, head);
          log(`inject ${repo}#${pr.number} (head ${head.slice(0, 8)}, ${last ? 'Report veraltet' : 'kein Report'}) -> HTTP ${code}`);
          injected++;
        }
      }
    }
  }
  log(`catch-up fertig: ${checked} offene PRs geprueft, ${injected} eingespeist`);
})().catch(e => log('catch-up-error: ' + e.message));
