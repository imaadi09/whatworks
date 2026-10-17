// Temp diagnostic: fetch "New task for chk" doc from Firestore via REST.
const path = require('path');
const FT = path.join(process.env.APPDATA, 'npm', 'node_modules', 'firebase-tools', 'node_modules');
const { GoogleAuth } = require(path.join(FT, 'google-auth-library'));

const PROJECT = 'whatworks-68786';
const TITLE = process.argv[2] || 'New task for chk';

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
    scopes: ['https://www.googleapis.com/auth/datastore'],
  });
  const client = await auth.getClient();
  const token = (await client.getAccessToken()).token;

  const body = {
    structuredQuery: {
      from: [{ collectionId: 'tasks' }],
      where: {
        fieldFilter: {
          field: { fieldPath: 'title' },
          op: 'EQUAL',
          value: { stringValue: TITLE },
        },
      },
      limit: 5,
    },
  };

  const res = await fetch(
    `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents:runQuery`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }
  );
  const rows = await res.json();
  if (!Array.isArray(rows)) {
    console.log('ERROR', JSON.stringify(rows, null, 2));
    return;
  }
  let found = 0;
  for (const row of rows) {
    if (!row.document) continue;
    found++;
    const f = row.document.fields || {};
    const doc = {};
    for (const [k, v] of Object.entries(f)) doc[k] = fromFs(v);
    console.log('=== DOC', row.document.name.split('/').pop(), '===');
    const keep = [
      'title', 'createdBy', 'createdByName', 'createdByPhone',
      'assignedTo', 'assignedToUid', 'assignedToPhone',
      'participants', 'updatedAt', 'createdAt',
    ];
    for (const k of keep) console.log(k + ':', JSON.stringify(doc[k]));
    const ef = doc.extraFields || {};
    console.log('extraFields.assigneeNames:', JSON.stringify(ef.assigneeNames));
    console.log('extraFields.assigneeUids:', JSON.stringify(ef.assigneeUids));
    console.log('extraFields.assigneePhones:', JSON.stringify(ef.assigneePhones));
    console.log('extraFields.isDraft:', JSON.stringify(ef.isDraft));
    console.log('isClosed:', JSON.stringify(doc.isClosed), 'isCancelled:', JSON.stringify(doc.isCancelled), 'isDeleted:', JSON.stringify(doc.isDeleted));
  }
  if (!found) console.log('NO DOCUMENT FOUND with title:', TITLE);
})().catch((e) => console.error('FAILED:', e.message));
