// Temp diagnostic: dump identity fields of every task involving a given UID,
// so we can see whether the two contact-name variants of the same person share
// a UID or a normalized phone (which is what the picker merge relies on).
const path = require('path');
const FT = path.join(process.env.APPDATA, 'npm', 'node_modules', 'firebase-tools', 'node_modules');
const { GoogleAuth } = require(path.join(FT, 'google-auth-library'));

const PROJECT = 'whatworks-68786';
// UID whose tasks we want to inspect (default: Sonu).
const UID = process.argv[2] || 'bQHwJQPrqrgW77CU6sDxmprwCw82';

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

function normPhone(p) {
  if (!p) return null;
  let c = String(p).replace(/[^\d+]/g, '');
  if (!c) return null;
  if (c.startsWith('+')) c = c.slice(1);
  while (c.startsWith('0')) c = c.slice(1);
  if (!c) return null;
  if (c.length <= 12 && !c.startsWith('91')) c = '91' + c;
  return '+' + c;
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
          field: { fieldPath: 'participants' },
          op: 'ARRAY_CONTAINS',
          value: { stringValue: UID },
        },
      },
      limit: 100,
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

  // name(lower) -> { uids:Set, phones:Set, count }
  const identity = {};
  function note(name, uid, phone) {
    if (!name) return;
    const key = name.trim().toLowerCase();
    if (!key || key === 'user') return;
    const e = (identity[key] ??= { display: name.trim(), uids: new Set(), phones: new Set(), count: 0 });
    e.count++;
    if (uid) e.uids.add(uid);
    const np = normPhone(phone);
    if (np) e.phones.add(np);
  }

  let found = 0;
  for (const row of rows) {
    if (!row.document) continue;
    found++;
    const f = row.document.fields || {};
    const doc = {};
    for (const [k, v] of Object.entries(f)) doc[k] = fromFs(v);
    note(doc.createdByName, doc.createdBy, doc.createdByPhone);
    const ef = doc.extraFields || {};
    const names = ef.assigneeNames;
    if (Array.isArray(names) && names.length > 1) {
      const uids = Array.isArray(ef.assigneeUids) && ef.assigneeUids.length === names.length ? ef.assigneeUids : null;
      const phones = Array.isArray(ef.assigneePhones) && ef.assigneePhones.length === names.length ? ef.assigneePhones : null;
      for (let i = 0; i < names.length; i++) {
        note(names[i], uids ? uids[i] : null, phones ? phones[i] : null);
      }
    } else {
      note(doc.assignedTo, doc.assignedToUid, doc.assignedToPhone);
    }
  }

  console.log('Tasks scanned:', found, 'for participant', UID);
  console.log('=== distinct names / their uids+phones ===');
  for (const [key, e] of Object.entries(identity)) {
    console.log(
      `\n"${e.display}"  (mentions: ${e.count})`,
      `\n   uids:   ${[...e.uids].join(', ') || '(none)'}`,
      `\n   phones: ${[...e.phones].join(', ') || '(none)'}`
    );
  }
})().catch((e) => console.error('FAILED:', e.message));
