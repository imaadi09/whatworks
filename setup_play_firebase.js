// One-off: register com.whatworks.app in Firebase project whatworks-68786,
// add debug + upload SHA certs, and download the new google-services.json.
// Run: & "C:\Program Files\nodejs\node.exe" setup_play_firebase.js
const path = require('path');
const fs = require('fs');
const gaPath = path.join(
  process.env.APPDATA, 'npm', 'node_modules', 'firebase-tools',
  'node_modules', 'google-auth-library'
);
const { GoogleAuth } = require(gaPath);

const PROJECT = 'whatworks-68786';
const PKG = 'com.whatworks.app';
const API = 'https://firebase.googleapis.com/v1beta1';
const SHAS = [
  // debug keystore (local flutter run)
  { shaHash: '9f0aff54d7e15be32931277fb5310a8ab9b37e82', certType: 'SHA_1' },
  { shaHash: '45efdabd1acd2ea4f4aae25e94c6dcce33e76a6d5c67ecb72369e0d3aab3ec10', certType: 'SHA_256' },
  // upload keystore (Play release)
  { shaHash: 'd76671ca747ca6f92fcd721aed337cb0f917bed8', certType: 'SHA_1' },
  { shaHash: 'aa4f98689782412607348e7629a3953ae80f9170dd50063c2f3188685f1c52bf', certType: 'SHA_256' },
];

(async () => {
  const auth = new GoogleAuth({
    keyFile: path.join(__dirname, 'service-account.json'),
    scopes: ['https://www.googleapis.com/auth/cloud-platform'],
  });
  const client = await auth.getClient();
  const headers = {
    ...(await client.getRequestHeaders()),
    'Content-Type': 'application/json',
  };

  // 1) Find or create the Android app
  let res = await fetch(`${API}/projects/${PROJECT}/androidApps?pageSize=100`, { headers });
  let body = await res.json();
  if (!res.ok) throw new Error('list apps failed: ' + JSON.stringify(body));
  let app = (body.apps || []).find(a => a.packageName === PKG);

  if (!app) {
    res = await fetch(`${API}/projects/${PROJECT}/androidApps`, {
      method: 'POST', headers,
      body: JSON.stringify({ packageName: PKG, displayName: 'WhatWorks (Play)' }),
    });
    body = await res.json();
    if (!res.ok) throw new Error('create app failed: ' + JSON.stringify(body));
    // Poll the long-running operation
    let opName = body.name;
    for (let i = 0; i < 30; i++) {
      await new Promise(r => setTimeout(r, 2000));
      res = await fetch(`https://firebase.googleapis.com/v1beta1/${opName}`, { headers });
      body = await res.json();
      if (body.done) break;
    }
    if (!body.done || body.error) throw new Error('operation failed: ' + JSON.stringify(body));
    app = body.response;
    console.log('Created Android app:', app.appId);
  } else {
    console.log('Android app already exists:', app.appId);
  }

  // 2) Add SHA certificates (skip ones already present)
  res = await fetch(`${API}/projects/-/androidApps/${app.appId}/sha`, { headers });
  body = await res.json();
  const existing = new Set((body.certificates || []).map(c => c.shaHash.toLowerCase()));
  for (const sha of SHAS) {
    if (existing.has(sha.shaHash)) { console.log('SHA already present:', sha.shaHash); continue; }
    res = await fetch(`${API}/projects/-/androidApps/${app.appId}/sha`, {
      method: 'POST', headers, body: JSON.stringify(sha),
    });
    body = await res.json();
    if (!res.ok) throw new Error('add sha failed: ' + JSON.stringify(body));
    console.log('Added', sha.certType, sha.shaHash);
  }

  // 3) Download config and write all three google-services.json copies
  res = await fetch(`${API}/projects/-/androidApps/${app.appId}/config`, { headers });
  body = await res.json();
  if (!res.ok) throw new Error('get config failed: ' + JSON.stringify(body));
  const cfg = Buffer.from(body.configFileContents, 'base64').toString('utf8');
  for (const p of ['android/app/google-services.json', 'android/google-services.json', 'google-services.json']) {
    fs.writeFileSync(path.join(__dirname, p), cfg);
    console.log('Wrote', p);
  }
  console.log('Done.');
})().catch(e => { console.error(e.message || e); process.exit(1); });
