// One-off repair: stamp missing assignee identity on tasks whose
// assignedToUid is null but whose assignedTo name matches exactly one
// in-app user (and is not the creator). Sets assignedToUid, assignedToPhone
// and adds the uid to participants, bumping updatedAt so delta sync
// delivers the doc to the assignee device.
// Usage: node repair_assignee.js            (dry run)
//        node repair_assignee.js --apply    (write patches)
const path = require('path');
const FT = path.join(process.env.APPDATA, 'npm', 'node_modules', 'firebase-tools', 'node_modules');
const { GoogleAuth } = require(path.join(FT, 'google-auth-library'));

const PROJECT = 'whatworks-68786';
const APPLY = process.argv.includes('--apply');

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

async function runQuery(auth, body) {
  const client = await auth.getClient();
  const token = (await client.getAccessToken()).token;
  const res = await fetch(
    `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents:runQuery`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }
  );
  const rows = await res.json();
  if (!Array.isArray(rows)) throw new Error(JSON.stringify(rows).slice(0, 400));
  return rows.filter((r) => r.document).map((r) => {
    const doc = {};
    for (const [k, v] of Object.entries(r.document.fields || {})) doc[k] = fromFs(v);
    doc.__id = r.document.name.split('/').pop();
    return doc;
  });
}

async function patchDoc(auth, id, fields, masks) {
  const client = await auth.getClient();
  const token = (await client.getAccessToken()).token;
  const qs = masks.map((m) => `updateMask.fieldPaths=${encodeURIComponent(m)}`).join('&');
  const res = await fetch(
    `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/tasks/${id}?${qs}`,
    {
      method: 'PATCH',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ fields }),
    }
  );
  if (!res.ok) throw new Error(`PATCH ${id} -> ${res.status}: ${(await res.text()).slice(0, 300)}`);
}

(async () => {
  const auth = new GoogleAuth({
    keyFile: 'service-account.json',
    scopes: ['https://www.googleapis.com/auth/datastore'],
  });

  // 1. Load the in-app user directory: name(lower) -> [{uid, phone}]
  const users = await runQuery(auth, { structuredQuery: { from: [{ collectionId: 'users' }], limit: 500 } });
  const byName = {};
  for (const u of users) {
    const key = String(u.name || '').trim().toLowerCase();
    if (!key) continue;
    (byName[key] ??= []).push({ uid: u.__id, phone: normPhone(u.phone) });
  }
  console.log(`Users loaded: ${users.length}; distinct names: ${Object.keys(byName.length ? byName : {}).length}`);

  // 2. Find tasks with no assignedToUid
  const tasks = await runQuery(auth, {
    structuredQuery: {
      from: [{ collectionId: 'tasks' }],
      where: { unaryFilter: { field: { fieldPath: 'assignedToUid' }, op: 'IS_NULL' } },
      limit: 500,
    },
  });
  console.log(`Tasks with assignedToUid null: ${tasks.length}`);

  let patched = 0;
  for (const t of tasks) {
    if (t.isDeleted === true) { console.log(`SKIP deleted id=${t.__id} title="${t.title}"`); continue; }
    const name = String(t.assignedTo || '').trim().toLowerCase();
    if (!name) { console.log(`SKIP no-assignee id=${t.__id} title="${t.title}"`); continue; }
    const candidates = (byName[name] || []).filter((c) => c.uid !== t.createdBy);
    if (candidates.length !== 1) {
      console.log(`SKIP "${t.title}" (id=${t.__id}) -> assignee "${name}" matches ${candidates.length} users`);
      continue;
    }
    const target = candidates[0];
    const participants = Array.isArray(t.participants) ? [...t.participants] : [];
    if (!participants.includes(target.uid)) participants.push(target.uid);

    const fields = {
      assignedToUid: { stringValue: target.uid },
      participants: { arrayValue: { values: participants.map((p) => ({ stringValue: p })) } },
      updatedAt: { timestampValue: new Date().toISOString() },
    };
    const masks = ['assignedToUid', 'participants', 'updatedAt'];
    if (target.phone) {
      fields.assignedToPhone = { stringValue: target.phone };
      masks.push('assignedToPhone');
    }

    console.log(
      `${APPLY ? 'PATCH' : 'WOULD PATCH'} id=${t.__id} title="${t.title}" createdBy=${t.createdBy} ->`,
      `uid=${target.uid} phone=${target.phone} participants=${JSON.stringify(participants)}`
    );
    if (APPLY) await patchDoc(auth, t.__id, fields, masks);
    patched++;
  }
  console.log(`${APPLY ? 'Patched' : 'Would patch'} ${patched} task(s).`);
})().catch((e) => console.error('FAILED:', e.message));
