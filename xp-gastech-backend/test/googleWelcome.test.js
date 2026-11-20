const test = require('node:test');
const assert = require('node:assert/strict');

process.env.JWT_SECRET = 'test-secret';
const { OAuth2Client } = require('google-auth-library');
const { pool } = require('../src/db/pool');
const mailer = require('../src/services/sendchampEmail');
const { loginWithGoogleIdToken } = require('../src/services/googleAuth');

const ENV = ['SENDCHAMP_PUBLIC_KEY', 'SENDCHAMP_EMAIL_FROM', 'GOOGLE_CLIENT_ID', 'EMAIL_WELCOME_HTML', 'EMAIL_WELCOME_SUBJECT'];
const saved = {};
const realQuery = pool.query;
const realVerify = OAuth2Client.prototype.verifyIdToken;
let mails;

function google(payload) {
  OAuth2Client.prototype.verifyIdToken = async () => ({ getPayload: () => payload });
}

// existingRow: the users row found by email, or null for a brand-new account.
function db(existingRow) {
  const calls = [];
  pool.query = async (sql, params) => {
    calls.push(sql);
    if (/from users where email/.test(sql)) return { rows: existingRow ? [existingRow] : [] };
    if (/^\s*(update users|insert into users)/.test(sql)) {
      return { rows: [{ id: 'u1', email: params[0] === 'u1' ? existingRow.email : params[0], phone: null, phone_verified_at: null, email_verified_at: new Date(), created_at: new Date() }] };
    }
    if (/auth_sessions/.test(sql)) return { rows: [{ id: 's1', family_id: 'f1' }], rowCount: 1 };
    return { rows: [] };
  };
  return calls;
}

test.beforeEach(() => {
  for (const k of ENV) { saved[k] = process.env[k]; delete process.env[k]; }
  process.env.GOOGLE_CLIENT_ID = 'cid.apps.googleusercontent.com';
  process.env.SENDCHAMP_PUBLIC_KEY = 'k_test';
  process.env.SENDCHAMP_EMAIL_FROM = 'no-reply@xptechltd.com';
  mails = [];
  mailer.setTransport(async ({ payload }) => { mails.push(payload); return { status: 200, text: '{}' }; });
});
test.afterEach(() => {
  pool.query = realQuery;
  OAuth2Client.prototype.verifyIdToken = realVerify;
  mailer.setTransport(null);
  for (const k of ENV) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
});

test('google: first sign-up gets a welcome email addressed by given name', async () => {
  google({ email: 'New.User@Gmail.com', email_verified: true, name: 'Ada Lovelace', given_name: 'Ada' });
  db(null);
  const r = await loginWithGoogleIdToken('tok');
  assert.ok(r.token);
  assert.equal(mails.length, 1);
  assert.deepEqual(mails[0].to, [{ email: 'new.user@gmail.com', name: 'Ada' }]);
  assert.equal(mails[0].subject, 'Welcome to XP Tech, Ada');
  assert.match(mails[0].message_body.value, /Welcome to XP Tech, Ada/);
});

test('google: returning verified user gets no email', async () => {
  google({ email: 'old@gmail.com', email_verified: true, name: 'Old' });
  db({ id: 'u1', email: 'old@gmail.com', email_verified_at: new Date() });
  const r = await loginWithGoogleIdToken('tok');
  assert.ok(r.token);
  assert.equal(mails.length, 0);
});

test('google: existing never-verified email account gets its welcome on first Google sign-in', async () => {
  google({ email: 'pending@gmail.com', email_verified: true });
  db({ id: 'u1', email: 'pending@gmail.com', email_verified_at: null });
  await loginWithGoogleIdToken('tok');
  assert.equal(mails.length, 1);
  assert.deepEqual(mails[0].to, [{ email: 'pending@gmail.com', name: 'pending' }]);
});

test('google: welcome failure or slowness never breaks or holds sign-in', async () => {
  google({ email: 'a@gmail.com', email_verified: true, given_name: 'A' });
  db(null);
  mailer.setTransport(async () => { throw new Error('provider down'); });
  assert.ok((await loginWithGoogleIdToken('tok')).token);

  mailer.setTransport(() => new Promise(() => {})); // never answers
  const t0 = Date.now();
  assert.ok((await loginWithGoogleIdToken('tok')).token);
  const waited = Date.now() - t0;
  assert.ok(waited >= 2000 && waited < 4000, `waited ${waited}ms`);

  delete process.env.SENDCHAMP_EMAIL_FROM; // email not configured: no attempt, no wait
  let tried = false;
  mailer.setTransport(async () => { tried = true; return { status: 200, text: '' }; });
  assert.ok((await loginWithGoogleIdToken('tok')).token);
  assert.equal(tried, false);
});
