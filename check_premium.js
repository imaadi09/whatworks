// Read-only: report planType for both test users.
// Run: & "C:\Program Files\nodejs\node.exe" check_premium.js
const path = require('path');
const gaPath = path.join(
  process.env.APPDATA, 'npm', 'node_modules', 'firebase-tools',
  'node_modules', 'google-auth-library'
);
const { GoogleAuth } = require(gaPath);

const PROJECT = 'whatworks-68786';
const UIDS = [
  'mINOzSAKIERFNkdmbcuxhbp98U62', // Aditya +917999387646
  'bQHwJQPrqrgW77CU6sDxmprwCw82', // Sonu +917000936431
];

(async () => {
  const auth = new GoogleAuth({
    keyFile: path.join(__dirname, 'service-account.json'),
    scopes: ['https://www.googleapis.com/auth/cloud-platform'],
  });
  const client = await auth.getClient();
  const headers = await client.getRequestHeaders();

  for (const uid of UIDS) {
    const url = `https://firestore.googleapis.com/v1/projects/${PROJECT}` +
      `/databases/(default)/documents/users/${uid}`;
    const res = await fetch(url, { headers });
    if (!res.ok) {
      console.log(uid, '-> read failed:', res.status);
      continue;
    }
    const doc = await res.json();
    console.log(
      (doc.fields?.name?.stringValue || '?').padEnd(10),
      (doc.fields?.phone?.stringValue || '?').padEnd(14),
      'planType =', doc.fields?.planType?.stringValue || '(not set)'
    );
  }
})();
