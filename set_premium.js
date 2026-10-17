// One-off: set planType='enterprise' on users/mINOzSAKIERFNkdmbcuxhbp98U62
// (Aditya, +917999387646) for premium testing.
// Run: & "C:\Program Files\nodejs\node.exe" set_premium.js
const path = require('path');
const gaPath = path.join(
  process.env.APPDATA, 'npm', 'node_modules', 'firebase-tools',
  'node_modules', 'google-auth-library'
);
const { GoogleAuth } = require(gaPath);

const PROJECT = 'whatworks-68786';
const UID = 'mINOzSAKIERFNkdmbcuxhbp98U62';
const DOC = `projects/${PROJECT}/databases/(default)/documents/users/${UID}`;

(async () => {
  const auth = new GoogleAuth({
    keyFile: path.join(__dirname, 'service-account.json'),
    scopes: ['https://www.googleapis.com/auth/cloud-platform'],
  });
  const client = await auth.getClient();
  const headers = await client.getRequestHeaders();

  const url =
    `https://firestore.googleapis.com/v1/${DOC}?updateMask.fieldPaths=planType`;
  const res = await fetch(url, {
    method: 'PATCH',
    headers: { ...headers, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      fields: { planType: { stringValue: 'enterprise' } },
    }),
  });
  if (!res.ok) {
    console.error('PATCH failed:', res.status, await res.text());
    process.exit(1);
  }

  // Read back to verify
  const check = await fetch(`https://firestore.googleapis.com/v1/${DOC}`, {
    headers,
  });
  const doc = await check.json();
  console.log('users/' + UID);
  console.log('  phone   :', doc.fields?.phone?.stringValue);
  console.log('  name    :', doc.fields?.name?.stringValue);
  console.log('  planType:', doc.fields?.planType?.stringValue);
})();
