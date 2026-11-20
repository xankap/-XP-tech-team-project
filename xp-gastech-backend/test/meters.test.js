// Meter registration + offline reading upload.
// Unit tests always run. Integration runs against a Postgres with
// sql/001 + 004 + 005 + 007 applied, when TEST_DATABASE_URL is set:
//   TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55433/postgres?sslmode=disable \
//     node --test --test-concurrency=1 test/*.test.js   (PGlite socket = one connection)
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

process.env.JWT_SECRET = 'test-secret';
const DB_URL = process.env.TEST_DATABASE_URL;
if (DB_URL) {
  process.env.DATABASE_URL = DB_URL;
  process.env.PG_POOL_MAX = '1';
}

const jwt = require('jsonwebtoken');
const meters = require('../src/routes/meters');

test('btAddress normalises and rejects junk', () => {
  assert.equal(meters.btAddress('98:d3:31:aa:bb:cc'), '98:D3:31:AA:BB:CC');
  assert.equal(meters.btAddress(' 98-D3-31-AA-BB-CC '), '98:D3:31:AA:BB:CC');
  assert.equal(meters.btAddress('98d331aabbcc'), '98:D3:31:AA:BB:CC');
  for (const bad of ['', '98:D3:31:AA:BB', '98:D3:31:AA:BB:CC:DD', 'ZZ:D3:31:AA:BB:CC', '00:00:00:00:00:00', 'FF:FF:FF:FF:FF:FF', 42, null, "98:D3:31:AA:BB:CC'; drop table x"]) {
    assert.throws(() => meters.btAddress(bad), { status: 400 }, String(bad));
  }
});

test('parseReading validates every field', () => {
  const ok = { client_reading_id: crypto.randomUUID(), recorded_at: new Date().toISOString(), percent: 50, weight_kg: 5.5, battery: 90, leak_level: 0 };
  const r = meters.parseReading(ok);
  assert.equal(r.source, 'ble_offline');
  assert.equal(r.leak, 0);
  assert.equal(meters.parseReading({ ...ok, percent: undefined }).percent, null);
  const bads = [
    null, [], 'x',
    { ...ok, client_reading_id: 'nope' },
    { ...ok, recorded_at: 'yesterday' },
    { ...ok, recorded_at: new Date(Date.now() + 3600e3).toISOString() },
    { ...ok, recorded_at: '2020-01-01T00:00:00Z' },
    { ...ok, percent: 101 }, { ...ok, percent: 'NaN' }, { ...ok, weight_kg: -1 }, { ...ok, battery: 1000 },
    { ...ok, leak_level: 3 }, { ...ok, leak_level: '1' },
    { ...ok, percent: null, weight_kg: null },
    { ...ok, source: 'manual' },
  ];
  for (const b of bads) assert.throws(() => meters.parseReading(b), { status: 400 }, JSON.stringify(b));
});

test('integration: register, list, rename, upload (idempotent), ownership, remove/revive', { skip: !DB_URL && 'TEST_DATABASE_URL not set' }, async (t) => {
  const { app, pool } = require('../server');
  const server = app.listen(0);
  t.after(async () => { server.close(); await pool.end(); });
  const base = `http://127.0.0.1:${server.address().port}`;

  const mkUser = async () => {
    const { rows } = await pool.query("insert into public.users (email) values ($1) returning id", [`m${crypto.randomUUID()}@test.co`]);
    return { id: rows[0].id, token: jwt.sign({ sub: rows[0].id, typ: 'access' }, 'test-secret', { expiresIn: '1h' }) };
  };
  const call = async (user, method, path, body) => {
    const res = await fetch(base + path, {
      method,
      headers: { 'content-type': 'application/json', ...(user ? { authorization: `Bearer ${user.token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    return { status: res.status, body: text ? JSON.parse(text) : null };
  };
  const reading = (over = {}) => ({
    client_reading_id: crypto.randomUUID(), recorded_at: new Date(Date.now() - 60e3).toISOString(),
    percent: 64.5, weight_kg: 7.25, battery: 80, leak_level: 0, source: 'ble_offline', ...over,
  });

  // Random MAC so the suite can be re-run against the same database.
  const mac = crypto.randomBytes(6).toString('hex').toUpperCase().match(/.{2}/g).join(':');
  const alice = await mkUser();
  const bob = await mkUser();

  assert.equal((await call(null, 'GET', '/meters')).status, 401);

  // register
  let r = await call(alice, 'POST', '/meters', { btAddress: mac.toLowerCase(), label: 'Kitchen' });
  assert.equal(r.status, 201);
  assert.equal(r.body.meter.btAddress, mac);
  const meterId = r.body.meter.id;
  r = await call(alice, 'POST', '/meters', { btAddress: mac.replace(/:/g, '-') });
  assert.equal(r.status, 200, 'same meter again is idempotent');
  assert.equal(r.body.meter.id, meterId);
  assert.equal(r.body.meter.label, 'Kitchen');
  r = await call(bob, 'POST', '/meters', { btAddress: mac });
  assert.equal(r.status, 409);
  assert.equal(r.body.code, 'METER_TAKEN');
  assert.equal((await call(alice, 'POST', '/meters', { btAddress: 'bogus' })).status, 400);

  // list + rename
  r = await call(alice, 'GET', '/meters');
  assert.deepEqual(r.body.meters.map((m) => m.id), [meterId]);
  assert.deepEqual((await call(bob, 'GET', '/meters')).body.meters, []);
  r = await call(alice, 'PATCH', `/meters/${meterId}`, { label: 'Shop 2', cylinderSizeKg: 12.5 });
  assert.equal(r.status, 200);
  assert.equal(r.body.meter.label, 'Shop 2');
  assert.equal(r.body.meter.cylinderSizeKg, 12.5);
  assert.equal((await call(bob, 'PATCH', `/meters/${meterId}`, { label: 'mine' })).status, 404, 'foreign meter is invisible');
  assert.equal((await call(alice, 'PATCH', `/meters/${meterId}`, {})).status, 400);
  assert.equal((await call(alice, 'PATCH', '/meters/not-a-uuid', { label: 'x' })).status, 404);

  // upload
  const batch = [reading(), reading({ percent: 64, weight_kg: 7.2 }), reading({ leak_level: 2 })];
  r = await call(alice, 'POST', `/meters/${meterId}/readings`, { readings: batch });
  assert.equal(r.status, 200);
  assert.equal(r.body.inserted, 3);
  assert.deepEqual(r.body.accepted.sort(), batch.map((b) => b.client_reading_id).sort());
  assert.deepEqual(r.body.rejected, []);

  // retry of the same batch + one new + one invalid + in-batch duplicate
  const extra = reading({ percent: 63 });
  const invalid = reading({ percent: 150 });
  r = await call(alice, 'POST', `/meters/${meterId}/readings`, { readings: [...batch, extra, extra, invalid] });
  assert.equal(r.status, 200);
  assert.equal(r.body.inserted, 1);
  assert.equal(r.body.duplicates, 3);
  assert.equal(r.body.accepted.length, 4);
  assert.equal(r.body.rejected.length, 1);
  assert.equal(r.body.rejected[0].clientReadingId, invalid.client_reading_id);
  const { rows: cnt } = await pool.query('select count(*)::int n from public.meter_readings where meter_id = $1', [meterId]);
  assert.equal(cnt[0].n, 4, 'no duplicates stored');

  assert.equal((await call(bob, 'POST', `/meters/${meterId}/readings`, { readings: [reading()] })).status, 404);
  assert.equal((await call(alice, 'POST', `/meters/${meterId}/readings`, { readings: [] })).status, 400);
  r = await call(alice, 'POST', `/meters/${meterId}/readings`, { readings: Array.from({ length: 101 }, () => reading()) });
  assert.equal(r.status, 413);
  assert.equal(r.body.maxBatch, 100);

  r = await call(alice, 'GET', `/meters/${meterId}/readings?limit=2`);
  assert.equal(r.body.readings.length, 2);
  r = await call(alice, 'GET', '/meters');
  assert.ok(r.body.meters[0].lastReadingAt, 'last_reading_at updated');

  // remove (soft) -> gone from list, uploads 404, another account may claim it
  assert.equal((await call(bob, 'DELETE', `/meters/${meterId}`)).status, 404);
  assert.equal((await call(alice, 'DELETE', `/meters/${meterId}`)).status, 204);
  assert.equal((await call(alice, 'DELETE', `/meters/${meterId}`)).status, 404);
  assert.deepEqual((await call(alice, 'GET', '/meters')).body.meters, []);
  assert.equal((await call(alice, 'POST', `/meters/${meterId}/readings`, { readings: [reading()] })).status, 404);
  const { rows: kept } = await pool.query('select count(*)::int n from public.meter_readings where meter_id = $1', [meterId]);
  assert.equal(kept[0].n, 4, 'readings kept after soft delete');

  // re-register on same account revives the old record (history continuity)
  r = await call(alice, 'POST', '/meters', { btAddress: mac });
  assert.equal(r.status, 201);
  assert.equal(r.body.meter.id, meterId);
  assert.equal(r.body.meter.label, 'Shop 2');

  // after alice removes it, bob can register the physical meter (new record)
  await call(alice, 'DELETE', `/meters/${meterId}`);
  r = await call(bob, 'POST', '/meters', { btAddress: mac });
  assert.equal(r.status, 201);
  assert.notEqual(r.body.meter.id, meterId);

  // DB constraints back the API. (PGlite's socket server drops the
  // connection on the statement after an error, so a throw-away query
  // absorbs that; real Postgres doesn't need it.)
  const sqlError = async (sql) => {
    let code = 'no-error';
    try { await pool.query(sql); } catch (e) { code = e.code || e.message; }
    try { await pool.query('select 1'); } catch (_) { /* reconnect */ }
    return code;
  };
  assert.equal(await sqlError(`insert into public.meters (owner_user_id, bt_address) values ('${alice.id}', 'nope')`), '23514');
  assert.equal(await sqlError(`insert into public.meter_readings (meter_id, client_reading_id, recorded_at) values ('${meterId}', gen_random_uuid(), now())`), '23514');
  assert.equal(await sqlError(`insert into public.meter_readings (meter_id, client_reading_id, recorded_at, percent, leak_level) values ('${meterId}', gen_random_uuid(), now(), 5, 3)`), '23514');
  assert.equal(await sqlError(`insert into public.meters (owner_user_id, bt_address) values ('${alice.id}', '${mac}')`), '23505', 'one active owner per meter');

  // deleting the user cascades
  await pool.query('delete from public.users where id = $1', [alice.id]);
  const { rows: gone } = await pool.query('select (select count(*) from public.meters where id = $1)::int m, (select count(*) from public.meter_readings where meter_id = $1)::int r', [meterId]);
  assert.deepEqual(gone[0], { m: 0, r: 0 });
});
