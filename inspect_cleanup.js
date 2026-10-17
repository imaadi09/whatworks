// Temp diagnostic: verify the "auto delete on delivery" pipeline.
// 1) Lists Cloud Functions actually deployed to the project.
// 2) Collection-group scans all `messages` docs still on the server and
//    buckets them by parent collection, age, and receipt state.
const path = require('path');
const FT = path.join(process.env.APPDATA, 'npm', 'node_modules', 'firebase-tools', 'node_modules');
const { GoogleAuth } = require(path.join(FT, 'google-auth-library'));

const PROJECT = 'whatworks-68786';

function fromFs(v) {
  if (v == null) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('timestampValue' in v) return v.timestampValue;
  if ('nullValue' in v) return null;
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(fromFs);
  if ('mapValue' in v) {
    const o = {};
    for (const [k, x] of Object.entries(v.mapValue.fields || {})) o[k] = fromFs(x);
    return o;
  }
  return v;
}

(async () => {
  const auth = new GoogleAuth({
    keyFile: 'service-account.json',
    scopes: ['https://www.googleapis.com/auth/cloud-platform'],
  });
  const client = await auth.getClient();
  const token = (await client.getAccessToken()).token;
  const H = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };

  // ---- 1) Deployed Cloud Functions ----
  console.log('=== DEPLOYED CLOUD FUNCTIONS ===');
  const fnRes = await fetch(
    `https://cloudfunctions.googleapis.com/v2/projects/${PROJECT}/locations/-/functions`,
    { headers: H }
  );
  const fnJson = await fnRes.json();
  if (fnJson.error) {
    console.log('  (v2 list error):', fnJson.error.message);
  } else if (!fnJson.functions || fnJson.functions.length === 0) {
    console.log('  NONE DEPLOYED');
  } else {
    for (const f of fnJson.functions) {
      console.log(`  ${f.name.split('/').pop()}  state=${f.state}  updated=${f.updateTime}`);
    }
  }
  // also v1 (gen1 functions don't always show in v2 list on old projects)
  const fn1Res = await fetch(
    `https://cloudfunctions.googleapis.com/v1/projects/${PROJECT}/locations/-/functions`,
    { headers: H }
  );
  const fn1Json = await fn1Res.json();
  if (fn1Json.error) {
    console.log('  (v1 list error):', fn1Json.error.message);
  } else if (!fn1Json.functions || fn1Json.functions.length === 0) {
    console.log('  (v1) NONE DEPLOYED');
  } else {
    for (const f of fn1Json.functions) {
      console.log(`  (v1) ${f.name.split('/').pop()}  status=${f.status}  updated=${f.updateTime}`);
    }
  }

  // ---- 2) Collection-group scan of all `messages` docs ----
  console.log('\n=== SERVER MESSAGE DOCS (collection group: messages) ===');
  const now = Date.now();
  // stats per parent root collection
  const stats = {};
  let pageToken = null;
  let scanned = 0;
  const samples = [];
  do {
    const body = {
      structuredQuery: {
        from: [{ collectionId: 'messages', allDescendants: true }],
        orderBy: [{ field: { fieldPath: '__name__' }, direction: 'ASCENDING' }],
        limit: 300,
      },
    };
    if (pageToken) body.structuredQuery.startAt = pageToken;
    const res = await fetch(
      `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents:runQuery`,
      { method: 'POST', headers: H, body: JSON.stringify(body) }
    );
    const rows = await res.json();
    if (!Array.isArray(rows)) {
      console.log('QUERY ERROR', JSON.stringify(rows).slice(0, 500));
      break;
    }
    let lastDoc = null;
    let got = 0;
    for (const row of rows) {
      if (!row.document) continue;
      got++;
      scanned++;
      lastDoc = row.document;
      const parts = row.document.name.split('/documents/')[1].split('/');
      const root = parts[0]; // tasks | sales_enquiries | crm_records
      const f = row.document.fields || {};
      const d = {};
      for (const [k, v] of Object.entries(f)) d[k] = fromFs(v);
      const s = (stats[root] ??= {
        total: 0, deleted: 0, withFile: 0,
        noReceipts: 0, deliveredSome: 0, readSome: 0,
        olderThan7d: 0, oldest: null, newest: null,
      });
      s.total++;
      if (d.deleted === true) s.deleted++;
      if (d.fileUrl) s.withFile++;
      const dl = d.deliveredTo && Object.keys(d.deliveredTo).length > 0;
      const rd = d.readBy && Object.keys(d.readBy).length > 0;
      if (dl) s.deliveredSome++;
      if (rd) s.readSome++;
      if (!dl && !rd) s.noReceipts++;
      const ts = d.createdAt ? Date.parse(d.createdAt) : null;
      if (ts) {
        if (now - ts > 7 * 24 * 3600 * 1000) s.olderThan7d++;
        if (!s.oldest || ts < s.oldest) s.oldest = ts;
        if (!s.newest || ts > s.newest) s.newest = ts;
      }
      if (samples.length < 6 && now - (ts || now) > 7 * 24 * 3600 * 1000) {
        samples.push({
          path: parts.join('/'),
          createdAt: d.createdAt,
          senderId: (d.senderId || '').slice(0, 8),
          deliveredTo: d.deliveredTo ? Object.keys(d.deliveredTo).map(u => u.slice(0, 8)) : null,
          readBy: d.readBy ? Object.keys(d.readBy).map(u => u.slice(0, 8)) : null,
          deleted: d.deleted === true,
          hasFile: !!d.fileUrl,
        });
      }
    }
    // paginate via startAt on __name__ of last doc
    if (got === 300 && lastDoc) {
      pageToken = { values: [{ referenceValue: lastDoc.name }], before: false };
    } else {
      pageToken = null;
    }
  } while (pageToken && scanned < 6000);

  console.log('Total message docs on server:', scanned);
  for (const [root, s] of Object.entries(stats)) {
    console.log(`\n[${root}]`);
    console.log(`  total: ${s.total}   older than 7 days: ${s.olderThan7d}`);
    console.log(`  oldest: ${s.oldest ? new Date(s.oldest).toISOString() : '-'}   newest: ${s.newest ? new Date(s.newest).toISOString() : '-'}`);
    console.log(`  with deliveredTo: ${s.deliveredSome}   with readBy: ${s.readSome}   no receipts at all: ${s.noReceipts}`);
    console.log(`  soft-deleted flag: ${s.deleted}   still carrying fileUrl: ${s.withFile}`);
  }
  console.log('\n=== SAMPLE OLD DOCS (>7d) ===');
  for (const smp of samples) console.log(JSON.stringify(smp));

  // ---- 3) Storage attachments still on the server ----
  console.log('\n=== STORAGE OBJECTS ===');
  for (const bucket of [`${PROJECT}.appspot.com`, `${PROJECT}.firebasestorage.app`]) {
    let total = 0, bytes = 0, oldest = null, pt = null;
    let err = null;
    do {
      const u = new URL(`https://storage.googleapis.com/storage/v1/b/${bucket}/o`);
      u.searchParams.set('maxResults', '1000');
      if (pt) u.searchParams.set('pageToken', pt);
      const r = await fetch(u, { headers: H });
      const j = await r.json();
      if (j.error) { err = j.error.message; break; }
      for (const o of j.items || []) {
        total++;
        bytes += Number(o.size || 0);
        const t = Date.parse(o.timeCreated);
        if (!oldest || t < oldest) oldest = t;
      }
      pt = j.nextPageToken || null;
    } while (pt);
    if (err) console.log(`  ${bucket}: (${err})`);
    else console.log(`  ${bucket}: ${total} objects, ${(bytes / 1024 / 1024).toFixed(1)} MB, oldest ${oldest ? new Date(oldest).toISOString() : '-'}`);
  }
})().catch((e) => console.error('FAILED:', e.message));
