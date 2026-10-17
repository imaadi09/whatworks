/**
 * Sample receipt maps on a few task messages to see why all-read/all-delivered
 * never evaluates true. Dependency-free (same auth as audit.js).
 */
const crypto = require('crypto');
const https = require('https');
const sa = require('../service-account.json');
const PID = sa.project_id;

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function httpsReq(method, url, headers, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request({ method, hostname: u.hostname, path: u.pathname + u.search, headers }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        if (res.statusCode >= 400) reject(new Error(`${res.statusCode} ${data.slice(0, 300)}`));
        else resolve(JSON.parse(data || '{}'));
      });
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}
async function getToken() {
  const iat = Math.floor(Date.now() / 1000);
  const claims = { iss: sa.client_email, scope: 'https://www.googleapis.com/auth/datastore', aud: sa.token_uri, iat, exp: iat + 3600 };
  const unsigned = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' })) + '.' + b64url(JSON.stringify(claims));
  const sign = crypto.createSign('RSA-SHA256');
  sign.update(unsigned);
  const jwt = unsigned + '.' + b64url(sign.sign(sa.private_key));
  const body = `grant_type=${encodeURIComponent('urn:ietf:params:oauth:grant-type:jwt-bearer')}&assertion=${jwt}`;
  return (await httpsReq('POST', sa.token_uri, { 'Content-Type': 'application/x-www-form-urlencoded' }, body)).access_token;
}
function dec(v) {
  if (v == null) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('integerValue' in v) return parseInt(v.integerValue, 10);
  if ('timestampValue' in v) return v.timestampValue;
  if ('mapValue' in v) { const o = {}; for (const [k, val] of Object.entries(v.mapValue.fields || {})) o[k] = dec(val); return o; }
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(dec);
  return v;
}
function decodeDoc(d) { const o = {}; for (const [k, v] of Object.entries(d.fields || {})) o[k] = dec(v); o.__id = d.name.split('/').pop(); return o; }
const BASE = `https://firestore.googleapis.com/v1/projects/${PID}/databases/(default)/documents`;

async function main() {
  const token = await getToken();
  const H = { Authorization: 'Bearer ' + token };
  const tasksRes = await httpsReq('GET', `${BASE}/tasks?pageSize=5`, H);
  for (const td of (tasksRes.documents || []).slice(0, 3)) {
    const t = decodeDoc(td);
    console.log(`\n=== TASK ${t.__id} ===`);
    console.log('createdBy:', t.createdBy);
    console.log('assignedToUid:', t.assignedToUid);
    console.log('participants:', JSON.stringify(t.participants));
    const msgsRes = await httpsReq('GET', `${BASE}/tasks/${t.__id}/messages?pageSize=4`, H);
    for (const md of (msgsRes.documents || []).slice(0, 3)) {
      const m = decodeDoc(md);
      console.log(`  msg ${m.__id} type=${m.type || m.messageType || '?'} sender=${m.senderId}`);
      console.log('    readBy:', JSON.stringify(m.readBy));
      console.log('    deliveredTo:', JSON.stringify(m.deliveredTo));
      console.log('    downloadedBy:', JSON.stringify(m.downloadedBy));
    }
  }
}
main().catch((e) => { console.error('FAILED:', e.message); process.exit(1); });
