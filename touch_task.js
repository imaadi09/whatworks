// Temp remedy: bump a task's updatedAt to now so watermark-based delta sync
// re-delivers it to every participant device (rows older than a device's local
// watermark are otherwise never fetched again).
const path = require('path');
const FT = path.join(process.env.APPDATA, 'npm', 'node_modules', 'firebase-tools', 'node_modules');
const { GoogleAuth } = require(path.join(FT, 'google-auth-library'));

const PROJECT = 'whatworks-68786';
const DOC_ID = process.argv[2] || '1785306738855'; // "New task for chk"

(async () => {
  const auth = new GoogleAuth({
    keyFile: 'service-account.json',
    scopes: ['https://www.googleapis.com/auth/datastore'],
  });
  const client = await auth.getClient();
  const token = (await client.getAccessToken()).token;
  const base = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/tasks/${DOC_ID}`;

  const before = await (await fetch(base, { headers: { Authorization: `Bearer ${token}` } })).json();
  if (!before.fields) {
    console.log('DOC NOT FOUND', JSON.stringify(before, null, 2));
    return;
  }
  console.log('title    :', before.fields.title?.stringValue);
  console.log('old updatedAt:', before.fields.updatedAt?.timestampValue);

  const now = new Date().toISOString();
  const res = await fetch(`${base}?updateMask.fieldPaths=updatedAt`, {
    method: 'PATCH',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ fields: { updatedAt: { timestampValue: now } } }),
  });
  const after = await res.json();
  if (after.fields) {
    console.log('new updatedAt:', after.fields.updatedAt?.timestampValue, '  OK');
  } else {
    console.log('PATCH FAILED', JSON.stringify(after, null, 2));
  }
})().catch((e) => console.error('FAILED:', e.message));
