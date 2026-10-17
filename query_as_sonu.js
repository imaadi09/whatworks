// Temp diagnostic: run the EXACT participants sync query AS SONU (rules enforced)
// to check whether her device's listener would be rejected at runtime.
// 1) mint custom token (service account), 2) exchange for ID token, 3) runQuery.
const path = require('path');
const FT = path.join(process.env.APPDATA, 'npm', 'node_modules', 'firebase-tools', 'node_modules');
const { GoogleAuth } = require(path.join(FT, 'google-auth-library'));
const crypto = require('crypto');
const fs = require('fs');

const PROJECT = 'whatworks-68786';
const API_KEY = 'AIzaSyBywonZetLqGvevCJaXx3HJcisygeL4DH4';
const UID = process.argv[2] || 'bQHwJQPrqrgW77CU6sDxmprwCw82'; // Sonu

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

(async () => {
  const sa = JSON.parse(fs.readFileSync('service-account.json', 'utf8'));

  // Mint a Firebase custom token (JWT signed by the service account).
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const payload = b64url(JSON.stringify({
    iss: sa.client_email,
    sub: sa.client_email,
    aud: 'https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit',
    iat: now,
    exp: now + 3600,
    uid: UID,
  }));
  const signer = crypto.createSign('RSA-SHA256');
  signer.update(`${header}.${payload}`);
  const customToken = `${header}.${payload}.${b64url(signer.sign(sa.private_key))}`;

  // Exchange for an ID token.
  const exch = await (await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${API_KEY}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: customToken, returnSecureToken: true }),
    }
  )).json();
  if (!exch.idToken) {
    console.log('TOKEN EXCHANGE FAILED', JSON.stringify(exch, null, 2));
    return;
  }
  console.log('Signed in as', UID);

  // Run the exact sync query: participants array-contains UID AND updatedAt > watermark.
  const watermark = '2026-07-29T00:00:00Z';
  const body = {
    structuredQuery: {
      from: [{ collectionId: 'tasks' }],
      where: {
        compositeFilter: {
          op: 'AND',
          filters: [
            { fieldFilter: { field: { fieldPath: 'participants' }, op: 'ARRAY_CONTAINS', value: { stringValue: UID } } },
            { fieldFilter: { field: { fieldPath: 'updatedAt' }, op: 'GREATER_THAN', value: { timestampValue: watermark } } },
          ],
        },
      },
      limit: 50,
    },
  };
  const res = await (await fetch(
    `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents:runQuery`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${exch.idToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }
  )).json();

  if (!Array.isArray(res)) {
    console.log('QUERY ERROR', JSON.stringify(res, null, 2));
    return;
  }
  let n = 0;
  for (const row of res) {
    if (row.error) { console.log('ROW ERROR', JSON.stringify(row.error, null, 2)); continue; }
    if (!row.document) continue;
    n++;
    const f = row.document.fields;
    console.log('-', row.document.name.split('/').pop(), f.title?.stringValue, '| updatedAt', f.updatedAt?.timestampValue);
  }
  console.log(`Query AS SONU returned ${n} docs (watermark ${watermark})`);
})().catch((e) => console.error('FAILED:', e.message));
