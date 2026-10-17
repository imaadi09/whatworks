// Are the durable system_logs writes actually landing?
// Uses the Firestore REST API + the repo service account, matching the
// convention of the root-level list_indexes.js / inspect_task.js diagnostics
// (no firebase-admin needed). A collectionGroup query finds system_logs under
// every parent collection in one shot.
//
//   node tool\check_system_logs.js                  -> system_logs, no cutoff
//   node tool\check_system_logs.js messages         -> any other collectionGroup
//   node tool\check_system_logs.js system_logs 2026-09-14T07:49:48Z
//       -> also flags the newest doc per parent as BEFORE/AFTER that deploy time
//
// Run with node, never by double-clicking: Windows points .js at Windows Script
// Host, which fails on require() with "Microsoft JScript compilation error".
//
// Interpretation: only the app writes these documents, so ANY doc under
// tasks/*/system_logs proves the client was permitted to write it. Absence is
// NOT proof of a rules failure - the APK carrying the write-through may simply
// not have run since the deploy. Cross-check with a known-populated collection
// (pass `messages`) before concluding anything: that query shape returning 111
// rows while system_logs returns 0 is what turned a guess into a finding.
const path = require('path');
const REPO_ROOT = path.join(__dirname, '..');
const FT = path.join(
  process.env.APPDATA,
  'npm',
  'node_modules',
  'firebase-tools',
  'node_modules',
);
const { GoogleAuth } = require(path.join(FT, 'google-auth-library'));

const PROJECT = 'whatworks-68786';
const LIMIT = 400;

(async () => {
  const auth = new GoogleAuth({
    // Absolute so the script works from any working directory.
    keyFile: path.join(REPO_ROOT, 'service-account.json'),
    scopes: ['https://www.googleapis.com/auth/datastore'],
  });
  const client = await auth.getClient();
  const token = (await client.getAccessToken()).token;

  const collectionId = process.argv[2] || 'system_logs';
  // Deliberately not hardcoded: a baked-in deploy date silently goes stale the
  // moment the rules are redeployed, and every BEFORE/AFTER verdict it prints
  // becomes wrong. Pass it explicitly, or read it from
  // tool\check_deployed_rules.js.
  const since = process.argv[3] || null;

  const url = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents:runQuery`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({
      structuredQuery: {
        from: [{ collectionId, allDescendants: true }],
        limit: LIMIT,
      },
    }),
  });
  const text = await res.text();
  if (!res.ok) {
    console.log('HTTP', res.status, text.slice(0, 400));
    return;
  }

  // runQuery may return a JSON array or newline-delimited JSON objects.
  let parsed = [];
  try {
    const trimmed = text.trim();
    if (trimmed.startsWith('[')) {
      parsed = JSON.parse(trimmed);
    } else {
      parsed = trimmed
        .split('\n')
        .map((l) => l.trim())
        .filter(Boolean)
        .map((l) => JSON.parse(l));
    }
  } catch (e) {
    console.log('PARSE FAIL:', e.message);
    console.log('RAW HEAD:', JSON.stringify(text.slice(0, 300)));
    return;
  }
  const rows = parsed.filter((o) => o && o.document);

  console.log(`[${collectionId}] docs returned:`, rows.length, `(capped at ${LIMIT})`);
  if (rows.length === LIMIT) {
    console.log('  hit the cap - counts below are floors, not totals');
  }

  const byParent = {};
  for (const { document } of rows) {
    const afterDocs = document.name.split('/documents/')[1].split('/');
    const parent = afterDocs[0]; // tasks | sales_enquiries | crm_records | ...
    const created = document.fields && document.fields.createdAt
      ? document.fields.createdAt.timestampValue
      : null;
    const b = (byParent[parent] = byParent[parent] || { n: 0, oldest: null, newest: null });
    b.n++;
    if (created) {
      if (!b.oldest || created < b.oldest) b.oldest = created;
      if (!b.newest || created > b.newest) b.newest = created;
    }
  }

  for (const [parent, b] of Object.entries(byParent)) {
    console.log(
      `  ${parent.padEnd(16)} n=${String(b.n).padStart(4)}  oldest=${b.oldest || 'n/a'}  newest=${b.newest || 'n/a'}`,
    );
  }
  // The three parents that are supposed to have a system_logs subcollection.
  for (const p of ['tasks', 'sales_enquiries', 'crm_records']) {
    if (!byParent[p]) console.log(`  ${p.padEnd(16)} NO DOCS`);
  }

  if (!since) {
    console.log('\n(no deploy cutoff given - pass one as argv[3] for BEFORE/AFTER)');
    return;
  }
  console.log('\nCompare against deploy time:', since);
  for (const p of ['tasks', 'sales_enquiries', 'crm_records']) {
    const b = byParent[p];
    if (!b || !b.newest) continue;
    console.log(
      `  ${p.padEnd(16)} newest ${b.newest > since ? 'AFTER ' : 'BEFORE'} the deploy -> ${b.newest}`,
    );
  }
})().catch((e) => console.error('FAILED:', e.message));
