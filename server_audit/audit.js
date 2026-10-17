/**
 * Dependency-free read-only server audit (no npm packages needed).
 * Auth: signs a JWT with the service account key, exchanges it for an
 * OAuth token, then calls the Firestore + Storage REST APIs.
 * Usage: node audit.js
 */
const crypto = require('crypto');
const https = require('https');
const sa = require('../service-account.json');

const PID = sa.project_id;

// ── tiny helpers ────────────────────────────────────────────────────────
function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function httpsReq(method, url, headers, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request(
      { method, hostname: u.hostname, path: u.pathname + u.search, headers },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          if (res.statusCode >= 400) reject(new Error(`${res.statusCode} ${url}\n${data.slice(0, 500)}`));
          else resolve(JSON.parse(data || '{}'));
        });
      }
    );
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function getToken() {
  const iat = Math.floor(Date.now() / 1000);
  const claims = {
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/datastore https://www.googleapis.com/auth/devstorage.read_only',
    aud: sa.token_uri,
    iat,
    exp: iat + 3600,
  };
  const unsigned =
    b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' })) + '.' + b64url(JSON.stringify(claims));
  const sign = crypto.createSign('RSA-SHA256');
  sign.update(unsigned);
  const jwt = unsigned + '.' + b64url(sign.sign(sa.private_key));
  const body = `grant_type=${encodeURIComponent('urn:ietf:params:oauth:grant-type:jwt-bearer')}&assertion=${jwt}`;
  const res = await httpsReq('POST', sa.token_uri, { 'Content-Type': 'application/x-www-form-urlencoded' }, body);
  return res.access_token;
}

// ── Firestore REST value decoding ──────────────────────────────────────
function dec(v) {
  if (v == null) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('integerValue' in v) return parseInt(v.integerValue, 10);
  if ('doubleValue' in v) return v.doubleValue;
  if ('timestampValue' in v) return new Date(v.timestampValue);
  if ('nullValue' in v) return null;
  if ('mapValue' in v) {
    const o = {};
    for (const [k, val] of Object.entries(v.mapValue.fields || {})) o[k] = dec(val);
    return o;
  }
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(dec);
  return v;
}

function decodeDoc(d) {
  const o = {};
  for (const [k, v] of Object.entries(d.fields || {})) o[k] = dec(v);
  o.__id = d.name.split('/').pop();
  return o;
}

const BASE = `https://firestore.googleapis.com/v1/projects/${PID}/databases/(default)/documents`;

async function listAll(token, path) {
  const docs = [];
  let pageToken = '';
  do {
    const url = `${BASE}/${path}?pageSize=300${pageToken ? '&pageToken=' + pageToken : ''}`;
    const res = await httpsReq('GET', url, { Authorization: 'Bearer ' + token });
    for (const d of res.documents || []) docs.push(decodeDoc(d));
    pageToken = res.nextPageToken || '';
  } while (pageToken);
  return docs;
}

// ── audit logic ─────────────────────────────────────────────────────────
const DAY = 86400000;
const now = Date.now();
const age = (t) => (t instanceof Date ? (now - t.getTime()) / DAY : null);

async function auditColl(token, coll) {
  const parents = await listAll(token, coll);
  const s = {
    parents: parents.length,
    messages: 0,
    olderThan7d: 0,
    allRead: 0,
    allDelivered: 0,
    withAttachment: 0,
    softDeletedMsgs: 0,
    oldestMsgDays: 0,
  };
  for (const p of parents) {
    const participants = [
      ...new Set([p.createdBy, p.assignedToUid, ...(p.participants || [])].filter(Boolean)),
    ];
    const msgs = await listAll(token, `${coll}/${p.__id}/messages`);
    s.messages += msgs.length;
    for (const m of msgs) {
      const a = age(m.timestamp || m.createdAt);
      if (a !== null) {
        if (a > s.oldestMsgDays) s.oldestMsgDays = a;
        if (a > 7) s.olderThan7d++;
      }
      const readBy = m.readBy || {};
      const deliveredTo = m.deliveredTo || {};
      if (participants.length) {
        if (participants.every((u) => readBy[u])) s.allRead++;
        if (participants.every((u) => deliveredTo[u])) s.allDelivered++;
      }
      if (m.fileUrl) s.withAttachment++;
      if (m.isDeleted) s.softDeletedMsgs++;
    }
  }
  s.oldestMsgDays = Math.round(s.oldestMsgDays);
  return s;
}

async function main() {
  const token = await getToken();
  const out = {};
  for (const coll of ['tasks', 'sales_enquiries', 'crm_records']) {
    try {
      out[coll] = await auditColl(token, coll);
    } catch (e) {
      out[coll] = { error: e.message.split('\n')[0] };
    }
  }
  for (const coll of ['users', 'task_drafts', 'sales_teams', 'crm_teams', 'organizations', 'system_logs']) {
    try {
      const docs = await listAll(token, coll);
      out[coll] = { docs: docs.length };
    } catch (e) {
      out[coll] = { error: e.message.split('\n')[0] };
    }
  }
  // soft-deleted task docs (30-day purge candidates)
  try {
    const tasks = await listAll(token, 'tasks');
    out.softDeletedTaskDocs = tasks.filter((t) => t.isDeleted === true).length;
  } catch (e) {}

  // Storage buckets
  for (const bucket of [`${PID}.appspot.com`, `${PID}.firebasestorage.app`]) {
    try {
      const res = await httpsReq(
        'GET',
        `https://storage.googleapis.com/storage/v1/b/${bucket}/o?fields=items(name,size)&maxResults=1000`,
        { Authorization: 'Bearer ' + token }
      );
      const items = res.items || [];
      let bytes = 0;
      const byPrefix = {};
      for (const it of items) {
        bytes += parseInt(it.size, 10);
        const pre = it.name.split('/')[0];
        byPrefix[pre] = (byPrefix[pre] || 0) + 1;
      }
      out['storage:' + bucket] = { files: items.length, totalMB: (bytes / 1048576).toFixed(1), byPrefix };
    } catch (e) {
      out['storage:' + bucket] = { error: e.message.split('\n')[0] };
    }
  }
  console.log(JSON.stringify(out, null, 2));
}

main().catch((e) => {
  console.error('AUDIT FAILED:', e.message);
  process.exit(1);
});
