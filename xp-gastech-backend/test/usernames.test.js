const test = require('node:test');
const assert = require('node:assert/strict');

process.env.JWT_SECRET = 'test-secret';
const { pool } = require('../src/db/pool');
const mailer = require('../src/services/sendchampEmail');
const auth = require('../src/services/emailAuth');
const { normalizeUsername, isReserved, USERNAME_HINT } = require('../src/services/usernames');

const realQuery = pool.query;

test.beforeEach(() => {
  mailer.setTransport(async () => ({ status: 200, text: '{"id":"x"}' }));
});
test.afterEach(() => {
  pool.query = realQuery;
  mailer.setTransport(null);
});

test('normalizeUsername: lowercase, length, charset, reserved', () => {
  assert.equal(normalizeUsername(undefined), null);
  assert.equal(normalizeUsername(''), null);
  assert.equal(normalizeUsername('  XPTest7  '), 'xptest7');
  assert.equal(normalizeUsername('ab'), undefined);
  assert.equal(normalizeUsername('a'.repeat(21)), undefined);
  assert.equal(normalizeUsername('Bad Name'), undefined);
  assert.equal(normalizeUsername('ok_user.name'), 'ok_user.name');
  assert.equal(normalizeUsername('a@b.co'), undefined);
  assert.equal(isReserved('admin'), true);
  assert.equal(isReserved('xptest7'), false);
});

test('signup stores lowercase username; invalid and reserved rejected', async () => {
  process.env.SENDCHAMP_PUBLIC_KEY = 'k';
  process.env.SENDCHAMP_EMAIL_FROM = 'no-reply@xptechltd.com';
  let inserted;
  pool.query = async (sql, params = []) => {
    if (/insert into users/.test(sql)) {
      inserted = params;
      return { rows: [{ id: 'u1', email: params[0], phone: params[1], username: params[3] }] };
    }
    return { rows: [] };
  };
  const r = await auth.signup({ email: 'a@b.co', password: 'password123', username: 'XPTest7' });
  assert.equal(inserted[3], 'xptest7');
  assert.equal(r.user.username, 'xptest7');
  await assert.rejects(auth.signup({ email: 'a@b.co', password: 'password123', username: 'ab' }), { status: 400, message: USERNAME_HINT });
  await assert.rejects(auth.signup({ email: 'a@b.co', password: 'password123', username: 'admin' }), { status: 400, message: 'This username is not available' });
});

test('signup: username unique violation -> 409 USERNAME_TAKEN', async () => {
  pool.query = async (sql) => {
    if (/insert into users/.test(sql)) {
      const e = new Error('dup');
      e.code = '23505';
      e.constraint = 'users_username_unique';
      e.detail = 'Key (username)=(xptest7) already exists.';
      throw e;
    }
    return { rows: [] };
  };
  await assert.rejects(
    auth.signup({ email: 'a@b.co', password: 'password123', username: 'xptest7' }),
    { status: 409, code: 'USERNAME_TAKEN', message: 'Username already taken' }
  );
});

test('login accepts identifier as username (case-insensitive) or email', async () => {
  const bcrypt = require('bcryptjs');
  const hash = await bcrypt.hash('password123', 4);
  const row = { id: 'u1', email: 'a@b.co', phone: null, username: 'xptest7', password_hash: hash, email_verified_at: new Date() };
  const seen = [];
  pool.query = async (sql, params = []) => {
    seen.push({ sql, params });
    if (/from users where username = \$1/.test(sql) || /from users where email = \$1/.test(sql)) return { rows: [row] };
    if (/insert into public.auth_sessions|delete from public.auth_sessions/.test(sql)) {
      const e = new Error('undefined table');
      e.code = '42P01';
      throw e;
    }
    return { rows: [] };
  };
  const byUser = await auth.login({ identifier: 'XPTest7', password: 'password123' });
  assert.ok(byUser.token);
  assert.equal(byUser.user.username, 'xptest7');
  assert.ok(seen.some((q) => /username = \$1/.test(q.sql) && q.params[0] === 'xptest7'));
  const byEmail = await auth.login({ email: 'A@B.co', password: 'password123' });
  assert.ok(byEmail.token);
  assert.equal(byEmail.user.email, 'a@b.co');
  assert.ok(seen.some((q) => /email = \$1/.test(q.sql) && q.params[0] === 'a@b.co'));
});

test('checkUsernameAvailable and setUsername', async () => {
  const calls = [];
  pool.query = async (sql, params = []) => {
    calls.push({ sql, params });
    if (/select 1 from users where username/.test(sql)) {
      return { rows: params[0] === 'taken_user' ? [{ '?column?': 1 }] : [] };
    }
    if (/update users set username/.test(sql)) {
      if (params[0] === 'taken_user') {
        const e = new Error('dup');
        e.code = '23505';
        e.constraint = 'users_username_unique';
        throw e;
      }
      return { rows: [{ id: params[1], email: 'a@b.co', phone: null, username: params[0] }] };
    }
    return { rows: [] };
  };
  assert.deepEqual(await auth.checkUsernameAvailable('Free_Name'), { available: true, username: 'free_name' });
  assert.deepEqual(await auth.checkUsernameAvailable('taken_user'), { available: false, username: 'taken_user' });
  assert.deepEqual(await auth.checkUsernameAvailable('admin'), { available: false, username: 'admin' });
  await assert.rejects(auth.checkUsernameAvailable('x'), { status: 400 });
  const set = await auth.setUsername('u1', 'New.Name');
  assert.equal(set.user.username, 'new.name');
  await assert.rejects(auth.setUsername('u1', 'taken_user'), { status: 409, code: 'USERNAME_TAKEN' });
});
