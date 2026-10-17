// Temp diagnostic: look up user docs by phone / uid.
const path = require('path');
const FT = path.join(process.env.APPDATA, 'npm', 'node_modules', 'firebase-tools', 'node_modules');
const { GoogleAuth } = require(path.join(FT, 'google-auth-library'));

const PROJECT = 'whatworks-68786';

function fromFs(v) {
  if (v == null) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('booleanValue' in v) return v.booleanValue;
  if ('timestampValue' in v) return v.timestampValue;
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

  for (const uid of ['bQHwJQPrqrgW77CU6sDxmprwCw82', 'mINOzSAKIERFNkdmbcuxhbp98U62']) {
    const res = await fetch(
      `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/users/${uid}`,
      { headers: { Authorization: `Bearer ${token}` } }
    );
    const doc = await res.json();
    if (doc.fields) {
      const o = {};
      for (const [k, v] of Object.entries(doc.fields)) o[k] = fromFs(v);
      console.log(uid, '=>', JSON.stringify({ name: o.name, phone: o.phone }));
    } else {
      console.log(uid, '=> NOT FOUND', JSON.stringify(doc.error || doc));
    }
  }
})().catch((e) => console.error('FAILED:', e.message));
