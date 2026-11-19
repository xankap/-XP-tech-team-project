// Session / refresh-token tests.
// Unit tests always run. The integration suite runs against a real Postgres
// that has sql/001 + sql/004 + sql/005 applied, when TEST_DATABASE_URL is set:
//   TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/postgres npm test
const test = require('node:test');
const assert = require('node:assert/strict');

process.env.JWT_SECRET = 'test-secret';
const DB_URL = process.env.TEST_DATABASE_URL;
if (DB_URL) {
  process.env.DATABASE_URL = DB_URL;
  process.env.PG_POOL_MAX = '1';
}

const jwt = require('jsonwebtoken');
const express = require('express');
const { pool } = require('../src/db/pool');
const sessions = require('../src/services/sessions');

test('legacy fallback: missing auth_sessions table -> 7d access token, no refresh token', async () => {
  const real = pool.query;
  pool.query = async () => { const e = new Error('relation does not exist'); e.code = '42P01'; throw e; };
  try {
    const s = await sessions.issueSession({ id: '00000000-0000-0000-0000-000000000001', email: 'a@b.co' });
    assert.equal(s.refreshToken, undefined);
    const p = jwt.verify(s.token, 'test-secret');
    assert.equal(p.exp - p.iat, 7 * 24 * 3600);
    assert.equal(p.sid, undefined);
  } finally {
    pool.query = real;
  }
});

test('other DB errors are not swallowed', async () => {
  const real = pool.query;
  pool.query = async () => { const e = new Error('boom'); e.code = '57P01'; throw e; };
  try {
    await assert.rejects(sessions.issueSession({ id: 'x' }), { message: 'boom' });
  } finally {
    pool.query = real;
  }
});

test('refresh rejects malformed tokens without touching the DB', async () => {
  await assert.rejects(sessions.refreshSession(undefined), { status: 401, code: 'INVALID_REFRESH_TOKEN' });
  await assert.rejects(sessions.refreshSession('short'), { status: 401 });
});

test('hash is sha256 hex (matches migration check constraint)', () => {
  assert.match(sessions.hashRefreshToken('abc'), /^[0-9a-f]{64}$/);
});

test('integration: login session, refresh rotation, reuse detection, logout, /me', { skip: !DB_URL && 'TEST_DATABASE_URL not set' }, async (t) => {
  const authRoutes = require('../src/routes/auth');
  const app = express();
  app.set('trust proxy', 1);
  app.use(express.json());
  app.use('/auth', authRoutes);
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;
  t.after(() => new Promise((r) => server.close(r)));
  const post = (p, body, headers = {}) => fetch(base + p, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) });
  const me = (token) => fetch(base + '/auth/me', { headers: { authorization: `Bearer ${token}` } });

  const email = `it${Date.now()}@example.com`;
  const { rows } = await pool.query(`insert into users (email, email_verified_at) values ($1, now()) returning id, email, phone`, [email]);
  const user = rows[0];

  // Issue
  const s1 = await sessions.issueSession(user, { deviceLabel: 'android\u0000 test', userAgent: 'UA' });
  assert.ok(s1.refreshToken && s1.token);
  const p1 = jwt.verify(s1.token, 'test-secret');
  assert.equal(p1.exp - p1.iat, 3600);
  const stored = await pool.query(`select token_hash, device_label, family_id from auth_sessions where user_id = $1`, [user.id]);
  assert.equal(stored.rows.length, 1);
  assert.equal(stored.rows[0].token_hash, sessions.hashRefreshToken(s1.refreshToken));
  assert.notEqual(stored.rows[0].token_hash, s1.refreshToken, 'raw token never stored');
  assert.equal(stored.rows[0].device_label, 'android test');
  assert.equal(stored.rows[0].family_id, p1.sid);

  // /me works
  let r = await me(s1.token);
  assert.equal(r.status, 200);
  assert.equal((await r.json()).user.email, email);

  // Refresh rotates
  r = await post('/auth/refresh', { refreshToken: s1.refreshToken });
  assert.equal(r.status, 200);
  const s2 = await r.json();
  assert.ok(s2.refreshToken && s2.refreshToken !== s1.refreshToken);
  assert.equal(jwt.decode(s2.token).sid, p1.sid);
  assert.equal(s2.user.email, email);

  // Old token reused within grace window -> 409 race, family still alive
  r = await post('/auth/refresh', { refreshToken: s1.refreshToken });
  assert.equal(r.status, 409);
  assert.equal((await r.json()).code, 'REFRESH_RACE');
  assert.equal((await me(s2.token)).status, 200);

  // Old token reused after grace -> theft: whole family revoked
  await pool.query(`update auth_sessions set revoked_at = now() - interval '5 minutes' where token_hash = $1`, [sessions.hashRefreshToken(s1.refreshToken)]);
  r = await post('/auth/refresh', { refreshToken: s1.refreshToken });
  assert.equal(r.status, 401);
  assert.equal((await r.json()).code, 'INVALID_REFRESH_TOKEN');
  r = await post('/auth/refresh', { refreshToken: s2.refreshToken });
  assert.equal(r.status, 401, 'newest token also dead after reuse detection');
  r = await me(s2.token);
  assert.equal(r.status, 401, 'access token of revoked family rejected');
  assert.equal((await r.json()).code, 'SESSION_REVOKED');

  // New login, then logout revokes refresh + access immediately
  const s3 = await sessions.issueSession(user, {});
  assert.equal((await me(s3.token)).status, 200);
  r = await post('/auth/logout', { refreshToken: s3.refreshToken }, { authorization: `Bearer ${s3.token}` });
  assert.equal(r.status, 200);
  assert.equal((await me(s3.token)).status, 401);
  assert.equal((await post('/auth/refresh', { refreshToken: s3.refreshToken })).status, 401);
  // Logout is idempotent and never errors
  assert.equal((await post('/auth/logout', { refreshToken: s3.refreshToken })).status, 200);
  assert.equal((await post('/auth/logout', {})).status, 200);

  // Unknown / expired refresh tokens
  assert.equal((await post('/auth/refresh', { refreshToken: 'x'.repeat(43) })).status, 401);
  const s4 = await sessions.issueSession(user, {});
  await pool.query(`update auth_sessions set created_at = now() - interval '90 days', expires_at = now() - interval '1 day' where token_hash = $1`, [sessions.hashRefreshToken(s4.refreshToken)]);
  assert.equal((await post('/auth/refresh', { refreshToken: s4.refreshToken })).status, 401);
  assert.equal((await me(s4.token)).status, 401, 'expired session family rejects access token');

  // Legacy tokens without sid still work
  const legacy = sessions.signAccessToken(user, { expiresIn: '7d' });
  assert.equal((await me(legacy)).status, 200);

  // Purge removes rows expired/revoked long ago
  await pool.query(`update auth_sessions set created_at = now() - interval '120 days', expires_at = now() - interval '60 days' where token_hash = $1`, [sessions.hashRefreshToken(s4.refreshToken)]);
  const purged = await pool.query(`select public.purge_expired_auth_sessions() as n`);
  assert.ok(purged.rows[0].n >= 1);

  // Cascade on user delete
  await pool.query(`delete from users where id = $1`, [user.id]);
  const left = await pool.query(`select count(*)::int as n from auth_sessions where user_id = $1`, [user.id]);
  assert.equal(left.rows[0].n, 0);
  await pool.end();
});
