const { test } = require('node:test');
const assert = require('node:assert/strict');
const v = require('../src/validation');
const crypto = require('node:crypto');
const { parseArgs } = require('../scripts/review_retailer.js');

// Unit tests always run. Integration runs against a Postgres with
// sql/001 + sql/002 (PostGIS) applied, when TEST_DATABASE_URL is set:
//   TEST_DATABASE_URL=postgres://user:pass@host:5432/db?sslmode=require \
//     node --test test/retailers.test.js
process.env.JWT_SECRET = 'test-secret';
const DB_URL = process.env.TEST_DATABASE_URL;
if (DB_URL) {
  process.env.DATABASE_URL = DB_URL;
  process.env.PG_POOL_MAX = '1';
}
const jwt = require('jsonwebtoken');

test('review CLI parses list/review commands', () => {
  assert.deepEqual(parseArgs([]), { command: 'list', status: 'pending', limit: 50 });
  assert.deepEqual(parseArgs(['list', '--status', 'approved', '--limit=10']),
    { command: 'list', status: 'approved', limit: 10 });
  assert.throws(() => parseArgs(['list', '--status', 'bogus']), /--status must be one of/);
  assert.throws(() => parseArgs(['list', '--limit', '0']), /--limit must be an integer/);

  const id = '11111111-2222-3333-4444-555555555555';
  const by = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
  assert.deepEqual(
    parseArgs(['review', '--id', id, '--decision', 'approved', '--by', by]),
    { command: 'review', status: 'pending', limit: 50, id, decision: 'approved', reason: null, by });
  assert.equal(
    parseArgs(['review', `--id=${id}`, '--decision=rejected', '--reason', '  bad coords  ']).reason,
    'bad coords');
  assert.equal(parseArgs(['--help']).command, 'help');
  assert.throws(() => parseArgs(['review', '--id', id]), /--decision must be/);
  assert.throws(() => parseArgs(['review', '--id', id, '--decision', 'maybe']), /--decision must be/);
  assert.throws(() => parseArgs(['review', '--id', 'not-a-uuid', '--decision', 'approved']), /--id must be a valid uuid/);
  assert.throws(() => parseArgs(['review', '--id', id, '--decision', 'rejected']), /--reason is required/);
  assert.throws(() => parseArgs(['review', '--id', id, '--decision', 'rejected', '--reason', 'x']), /--reason must be 2-300/);
  assert.throws(() => parseArgs(['review', '--id', id, '--decision', 'approved', '--bogus', '1']), /unknown option/);
  assert.throws(() => parseArgs(['frobnicate']), /unknown command/);
});

test('integration: register, PATCH /me, review -> nearby visibility', { skip: !DB_URL && 'TEST_DATABASE_URL not set' }, async (t) => {
  const { app, pool } = require('../server');
  const server = app.listen(0);
  t.after(async () => { server.close(); await pool.end(); });
  const base = `http://127.0.0.1:${server.address().port}`;

  const mkUser = async (role) => {
    const { rows } = await pool.query(
      'insert into public.users (email) values ($1) returning id',
      [`r${crypto.randomUUID()}@test.co`]);
    const id = rows[0].id;
    if (role) await pool.query('update public.users set role = $1 where id = $2', [role, id]);
    return { id, token: jwt.sign({ sub: id, typ: 'access' }, 'test-secret', { expiresIn: '1h' }) };
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

  const owner = await mkUser();
  const admin = await mkUser('admin');
  t.after(async () => {
    await pool.query('delete from public.users where id = any($1)', [[owner.id, admin.id]]);
  });

  // register -> pending, invisible on the consumer map
  const reg = await call(owner, 'POST', '/retailers', {
    name: 'Test Gas Plant (LPG Refill Plant)', phone: '+2348012345678',
    address: '12 Station Road', state: 'Rivers', cityLga: 'Port Harcourt',
    latitude: 4.8156, longitude: 7.0498,
    pricePerKg: 1400,
  });
  assert.equal(reg.status, 201);
  assert.equal(reg.body.retailer.status, 'pending');
  assert.equal(reg.body.retailer.pricePerKg, 1400);
  const retailerId = reg.body.retailer.id;
  const nearby = () => call(null, 'GET', '/retailers/nearby?lat=4.8156&lng=7.0498&radius=10000');
  assert.deepEqual((await nearby()).body.stations, [], 'pending station is not listed');

  // PATCH /me updates state, cityLga and availability
  let r = await call(owner, 'PATCH', '/retailers/me',
    { state: 'Lagos', cityLga: 'Ikeja', isAvailable: true });
  assert.equal(r.status, 200);
  assert.equal(r.body.retailer.state, 'Lagos');
  assert.equal(r.body.retailer.cityLga, 'Ikeja');
  assert.equal(r.body.retailer.isAvailable, true);
  assert.equal(r.body.retailer.status, 'pending');

  // only admins can review
  assert.equal((await call(owner, 'POST', `/retailers/${retailerId}/review`, { decision: 'approved' })).status, 403);
  assert.equal((await call(admin, 'POST', `/retailers/${retailerId}/review`, { decision: 'maybe' })).status, 400);

  // approve -> immediately queryable in nearby
  r = await call(admin, 'POST', `/retailers/${retailerId}/review`, { decision: 'approved' });
  assert.equal(r.status, 200);
  assert.equal(r.body.retailer.status, 'approved');
  const approved = (await nearby()).body.stations;
  assert.equal(approved.length, 1);
  assert.equal(approved[0].id, retailerId);

  // toggling isAvailable:false keeps it visible as an out-of-stock station.
  assert.equal((await call(owner, 'PATCH', '/retailers/me', { isAvailable: false })).status, 200);
  assert.equal((await nearby()).body.stations[0].isAvailable, false);
  assert.equal((await nearby()).body.stations[0].pricePerKg, 1400);
  r = await call(owner, 'PATCH', '/retailers/me', { isAvailable: true });
  assert.equal(r.body.retailer.status, 'approved');
  assert.equal((await nearby()).body.stations.length, 1);

  // Price changes do not require another approval review.
  r = await call(owner, 'PATCH', '/retailers/me', { pricePerKg: 1450 });
  assert.equal(r.body.retailer.status, 'approved');
  assert.equal(r.body.retailer.pricePerKg, 1450);

  // rejecting excludes it again; rejections need a reason
  assert.equal((await call(admin, 'POST', `/retailers/${retailerId}/review`, { decision: 'rejected' })).status, 400);
  r = await call(admin, 'POST', `/retailers/${retailerId}/review`, { decision: 'rejected', reason: 'Test rejection' });
  assert.equal(r.status, 200);
  assert.equal(r.body.retailer.status, 'rejected');
  assert.deepEqual((await nearby()).body.stations, [], 'rejected station is not listed');

  // review metadata persisted for audit
  const { rows } = await pool.query(
    'select reviewed_by, reviewed_at from public.retailers where id = $1', [retailerId]);
  assert.equal(rows[0].reviewed_by, admin.id);
  assert.ok(rows[0].reviewed_at, 'reviewed_at set');
});

test('retailers validation: name, phone, coordinates', () => {
  assert.equal(v.text('TotalEnergies Gas Plant', 'name', { min: 2, max: 120 }), 'TotalEnergies Gas Plant');
  assert.throws(() => v.text(' ', 'name', { min: 2, max: 120 }), /name must be 2-120 characters/);

  // Phone E.164
  assert.equal(v.phone('+2348012345678'), '+2348012345678');
  assert.throws(() => v.phone('08012345678'), /phone must be in international format/);
  assert.throws(() => v.phone('notaphonenumber'), /phone must be in international format/);

  // Coordinates
  assert.equal(v.num('6.4520', 'latitude', { min: -90, max: 90 }), 6.452);
  assert.equal(v.num(7.5105, 'longitude', { min: -180, max: 180 }), 7.5105);
  assert.throws(() => v.num(95, 'latitude', { min: -90, max: 90 }), /latitude must be a number between -90 and 90/);
});

test('retailers validation: openingHours', () => {
  assert.equal(v.openingHours(undefined), null);
  assert.equal(v.openingHours(null), null);

  const validHours = {
    mon: { open: '08:00', close: '18:00' },
    tue: { open: '08:00', close: '18:00' },
  };
  const parsed = v.openingHours(validHours);
  assert.deepEqual(parsed.mon, { open: '08:00', close: '18:00' });
  assert.deepEqual(parsed.tue, { open: '08:00', close: '18:00' });

  assert.throws(() => v.openingHours({ invalidDay: { open: '08:00', close: '18:00' } }), /unknown day/);
  assert.throws(() => v.openingHours({ mon: { open: '8am', close: '6pm' } }), /HH:MM/);
});
