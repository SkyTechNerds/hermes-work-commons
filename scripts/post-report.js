// Postet QA-Report als PR-Kommentar. Status aus ENV-Variablen.
const icon = { pass: '✅', fail: '❌', warn: '⚠️', skip: '⏭️' };

function statusOf(name) {
  return (process.env[`STATUS_${name.toUpperCase().replace(/-/g, '_')}`] || 'skip').toLowerCase();
}

const checks = ['secrets', 'diff', 'lint', 'paths', 'reviews', 'code-review'];
const labels = {
  secrets: 'Secret-Scan',
  diff: 'Diff-Size',
  lint: 'Lint',
  paths: 'Path-Convention',
  reviews: 'Review-Coverage',
  'code-review': 'Code-Review'
};

module.exports = async ({ github, context }) => {
  const rows = checks.map(c => {
    const s = statusOf(c);
    return `| ${icon[s] || '❔'} | **${labels[c]}** | ${s} |`;
  }).join('\\n');

  const allGreen = checks.every(c => {
    const s = statusOf(c);
    return s === 'pass' || s === 'skip';
  });

  const pr = context.payload.pull_request;
  const base = pr.base.ref;
  const head = pr.head.ref;

  const body = [
    '## 🤖 hermes-work QA Report',
    '',
    `PR #${pr.number} · \`${head}\` → \`${base}\``,
    '',
    '| Status | Check | Result |',
    '|--------|-------|--------|',
    rows,
    '',
    allGreen ? '✅ **All checks green.**' : '⚠️ **Action required** — see failed checks.',
    '',
    '_[Posted by hermes-work-commons v1.0.1](https://github.com/SkyTechNerds/hermes-work-commons)_'
  ].join('\\n');

  await github.rest.issues.createComment({
    issue_number: context.issue.number,
    owner: context.repo.owner,
    repo: context.repo.repo,
    body
  });
};
