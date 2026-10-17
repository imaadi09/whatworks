// Temp diagnostic: list deployed Firestore composite indexes for tasks.
const path = require('path');
const FT = path.join(process.env.APPDATA, 'npm', 'node_modules', 'firebase-tools', 'node_modules');
const { GoogleAuth } = require(path.join(FT, 'google-auth-library'));

const PROJECT = 'whatworks-68786';

(async () => {
  const auth = new GoogleAuth({
    keyFile: 'service-account.json',
    scopes: ['https://www.googleapis.com/auth/datastore'],
  });
  const client = await auth.getClient();
  const token = (await client.getAccessToken()).token;

  const url = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/collectionGroups/-/indexes`;
  const res = await (await fetch(url, { headers: { Authorization: `Bearer ${token}` } })).json();
  const indexes = res.indexes || [];
  console.log('Deployed composite indexes:', indexes.length);
  for (const ix of indexes) {
    const cg = ix.name.split('/collectionGroups/')[1].split('/')[0];
    const fields = (ix.fields || [])
      .map((f) => `${f.fieldPath}${f.arrayConfig ? ':CONTAINS' : ':' + (f.order || '')}`)
      .join(', ');
    console.log(`- [${ix.state}] ${cg}: ${fields}`);
  }
  if (res.error) console.log('ERROR', JSON.stringify(res.error, null, 2));
})().catch((e) => console.error('FAILED:', e.message));
