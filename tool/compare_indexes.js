// Compares live Firestore composite indexes against firestore.indexes.json.
// Usage: node tool/compare_indexes.js <live_indexes.json>
// The live file may have a banner before the JSON array (firebase CLI output).
const fs = require('fs');
const livePath = process.argv[2];
let live = fs.readFileSync(livePath, 'utf8');
// firebase CLI wraps output in {indexes:[...], fieldOverrides:[...]} with a
// possible banner/progress noise before the JSON; parse defensively.
live = live.slice(live.indexOf('{'));
const parsed = JSON.parse(live);
const L = parsed.indexes;
const F = JSON.parse(fs.readFileSync('firestore.indexes.json', 'utf8')).indexes;

// Signature ignores the automatic __name__ tail the CLI adds.
const sig = (i) =>
  i.collectionGroup +
  ':' +
  i.fields
    .filter((x) => x.fieldPath !== '__name__')
    .map((x) => x.fieldPath + (x.arrayConfig ? '(arr)' : ''))
    .join('|');

const ls = new Set(L.map(sig));
const cs = new Set(F.map(sig));

console.log('live count:', L.length, '| file count:', F.length);
const missing = F.map(sig).filter((s) => !ls.has(s));
console.log('MISSING from live:', missing.length ? '\n  ' + missing.join('\n  ') : 'none');
const extra = [...new Set(L.map(sig).filter((s) => !cs.has(s)))];
console.log('LIVE-ONLY (undocumented):', extra.length ? '\n  ' + extra.join('\n  ') : 'none');
L.filter((i) => i.state !== 'ENABLED').forEach((i) =>
  console.log('NOT ENABLED:', sig(i), '->', i.state)
);
