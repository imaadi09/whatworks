// Which Firestore security rules are ACTUALLY live on the project?
// firebase-tools 15 has no rules-download command, so this goes straight to the
// Firebase Rules API. Read-only: GET requests only, nothing is created or
// released. Run with node, never by double-clicking (Windows associates .js
// with Windows Script Host, which reports "Microsoft JScript compilation
// error" on the require() below):
//   node tool\check_deployed_rules.js
//
// Paths verified against https://firebaserules.googleapis.com/$discovery/rest?version=v1
//   GET  v1/projects/{p}/releases          projects.releases.list
//   GET  v1/{name}                         projects.releases.get
//   GET  v1/{name}/rulesets                projects.rulesets.list
// Two gotchas learned the hard way:
//   * The Firestore release is named "cloud.firestore", NOT "firestore".
//   * rulesets.get returns NO inline source for this credential and
//     releases:getExecutable is IAM-denied (403), so the live rule TEXT cannot
//     be read here. Any marker scan over an empty haystack is meaningless - it
//     reports every marker absent, including ones known to be live. Verdict is
//     therefore built from the release timestamp instead.
const path = require('path');
const { execFileSync } = require('child_process');
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
const BASE = 'https://firebaserules.googleapis.com/v1/';

// Committer timestamp of the last commit touching the local rules file, or null
// if git cannot answer. Returned in ISO-8601 with offset, parseable by Date.
function localRulesCommitTime() {
  try {
    return execFileSync('git', ['log', '-1', '--format=%cI', '--', 'firestore.rules'], {
      cwd: REPO_ROOT,
      encoding: 'utf8',
    }).trim();
  } catch (e) {
    return null;
  }
}

(async () => {
  const auth = new GoogleAuth({
    // Absolute so the script works from any working directory.
    keyFile: path.join(REPO_ROOT, 'service-account.json'),
    scopes: ['https://www.googleapis.com/auth/cloud-platform'],
  });
  const client = await auth.getClient();
  const token = (await client.getAccessToken()).token;

  const get = async (url) => {
    const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    const text = await res.text();
    let body;
    try {
      body = JSON.parse(text);
    } catch (e) {
      throw new Error(`HTTP ${res.status} ${url} -> non-JSON:\n${text.slice(0, 200).replace(/\s+/g, ' ')}`);
    }
    if (!res.ok) throw new Error(`HTTP ${res.status} ${url}\n${JSON.stringify(body.error || body, null, 2)}`);
    return body;
  };

  console.log('--- releases on this project ---');
  const rel = await get(`${BASE}projects/${PROJECT}/releases?pageSize=20`);
  for (const r of rel.releases || []) {
    console.log(`  ${r.name}  ->  ${r.rulesetName}  (updated ${r.updateTime || r.createTime})`);
  }

  // The Firestore release is named "cloud.firestore", not "firestore".
  const live = (rel.releases || []).find((r) => r.name.endsWith('cloud.firestore'));
  if (!live) {
    console.log('\nno cloud.firestore release found - rules have never been deployed');
    return;
  }
  console.log('\n--- live firestore rules release ---');
  console.log('  release   :', live.name);
  console.log('  ruleset   :', live.rulesetName);
  console.log('  updated   :', live.updateTime || live.createTime);

  const ruleset = await get(`${BASE}${live.rulesetName}`);
  console.log('  ruleset created:', ruleset.createTime);
  // A ruleset created seconds before the release moved is the signature of a
  // real `firebase deploy` (compile + create + release), not a hand edit.
  const gapMs = new Date(live.updateTime) - new Date(ruleset.createTime);
  console.log(`  create->release gap: ${Math.round(gapMs / 1000)}s (a few seconds = genuine deploy)`);

  let sourceBytes = 0;
  for (const src of ruleset.sources || (ruleset.source ? [ruleset.source] : [])) {
    for (const f of src.files || []) {
      if (f.content) sourceBytes += Buffer.from(f.content, 'base64').toString('utf8').length;
    }
  }
  // A handful of bytes is a stub (an empty file list base64'd), not the rules.
  // Only treat it as real source above a threshold, or this line becomes the
  // same false signal the old marker scan produced.
  const hasSource = sourceBytes > 200;
  console.log(
    `  inline source: ${sourceBytes} bytes -> ` +
      (hasSource
        ? 'scannable'
        : 'NOT the rules (a real rules file is many KB). This credential cannot ' +
          'read live rule text, so CONTENT cannot be verified here - rely on the ' +
          'release time below, or prove it functionally with check_system_logs.js'),
  );
  if (hasSource) {
    console.log('  (source present, but no marker scan is implemented - add one if needed)');
  }

  console.log('\n--- is the live ruleset newer than the local rules file? ---');
  const local = localRulesCommitTime();
  if (!local) {
    console.log('  could not read git history for firestore.rules - compare manually');
    return;
  }
  const localMs = new Date(local).getTime();
  const liveMs = new Date(live.updateTime).getTime();
  console.log('  last commit touching firestore.rules:', local);
  console.log('  live rules released               :', live.updateTime);
  if (liveMs >= localMs) {
    console.log('  => DEPLOYED: the live release postdates that commit.');
  } else {
    console.log('  => NOT DEPLOYED YET: the commit is newer than the live release.');
    console.log('     run: firebase deploy --only firestore:rules --project ' + PROJECT);
  }
  console.log('\n  Note: this compares a COMMIT time with a DEPLOY time. An uncommitted');
  console.log('  edit to firestore.rules is invisible here - check `git status` too.');
})().catch((e) => console.error('FAILED:', e.message));
