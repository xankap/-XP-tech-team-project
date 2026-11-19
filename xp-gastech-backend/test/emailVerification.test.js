const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

process.env.JWT_SECRET = 'test-secret';
const { pool } = require('../src/db/pool');
const mailer = require('../src/services/sendchampEmail');
const auth = require('../src/services/emailAuth');

const ENV = ['SENDCHAMP_PUBLIC_KEY', 'SENDCHAMP_EMAIL_FROM', 'SENDCHAMP_EMAIL_FROM_NAME', 'API_BASE_URL', 'APP_BASE_URL', 'EMAIL_VERIFY_SUBJECT', 'EMAIL_VERIFY_HTML', 'EMAIL_WELCOME_HTML', 'EMAIL_WELCOME_SUBJECT', 'SMS_OTP_TEMPLATE'];
const saved = {};
const realQuery = pool.query;
let queries;
let mails;

function setDb(handler) {
  queries = [];
  pool.query = async (sql, params) => {
    queries.push({ sql, params });
    return handler(sql, params || []);
  };
}

function configure() {
  process.env.SENDCHAMP_PUBLIC_KEY = 'k_test';
  process.env.SENDCHAMP_EMAIL_FROM = 'no-reply@xptechltd.com';
}

test.beforeEach(() => {
  for (const k of ENV) { saved[k] = process.env[k]; delete process.env[k]; }
  mails = [];
  mailer.setTransport(async ({ apiKey, payload }) => {
    mails.push({ apiKey, payload });
    return { status: 200, text: '{"id":"x"}' };
  });
});
test.afterEach(() => {
  pool.query = realQuery;
  mailer.setTransport(null);
  for (const k of ENV) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
});

const sha = (t) => crypto.createHash('sha256').update(t).digest('hex');

test('email config: configured only with key AND from address; defaults', () => {
  let c = mailer.getEmailConfig();
  assert.equal(c.configured, false);
  assert.equal(c.fromName, 'XP GasTech');
  assert.equal(c.apiBaseUrl, 'https://api.xptechltd.com');
  process.env.SENDCHAMP_PUBLIC_KEY = 'k';
  assert.equal(mailer.getEmailConfig().configured, false);
  process.env.SENDCHAMP_EMAIL_FROM = 'no-reply@xptechltd.com';
  process.env.API_BASE_URL = 'https://api.example.com/';
  c = mailer.getEmailConfig();
  assert.equal(c.configured, true);
  assert.equal(c.apiBaseUrl, 'https://api.example.com');
});

test('sendEmail: sends Sendchamp payload; errors map to EMAIL_SEND_FAILED', async () => {
  await assert.rejects(mailer.sendEmail({ to: 'a@b.co', subject: 's', html: 'h' }), { code: 'EMAIL_NOT_CONFIGURED' });
  configure();
  await mailer.sendEmail({ to: 'a@b.co', name: 'Ann', subject: 'S', html: '<p>h</p>' });
  assert.equal(mails[0].apiKey, 'k_test');
  assert.deepEqual(mails[0].payload, {
    subject: 'S',
    to: [{ email: 'a@b.co', name: 'Ann' }],
    from: { email: 'no-reply@xptechltd.com', name: 'XP GasTech' },
    message_body: { type: 'text/html', value: '<p>h</p>' },
  });
  mailer.setTransport(async () => ({ status: 400, text: '{"status":"failed","code":400,"message":"no active subscription. Please subscribe on dashboard"}' }));
  await assert.rejects(mailer.sendEmail({ to: 'a@b.co', subject: 's', html: 'h' }), (e) => e.code === 'EMAIL_SEND_FAILED' && e.providerResponse.code === 400);
  mailer.setTransport(async () => ({ status: 200, text: '{"status":"failed","message":"x"}' }));
  await assert.rejects(mailer.sendEmail({ to: 'a@b.co', subject: 's', html: 'h' }), { code: 'EMAIL_SEND_FAILED' });
  mailer.setTransport(async () => { throw new Error('boom'); });
  await assert.rejects(mailer.sendEmail({ to: 'a@b.co', subject: 's', html: 'h' }), { code: 'EMAIL_SEND_FAILED' });
  mailer.setTransport(async () => ({ status: 200, text: '' }));
  assert.equal(await mailer.sendEmail({ to: 'a@b.co', subject: 's', html: 'h' }), true);
});

test('templates: placeholders rendered + escaped; env override works', () => {
  const v = mailer.verificationEmail({ email: 'ann<x>@b.co', link: 'https://api.x/auth/verify-email?token=abc&a=1' });
  assert.match(v.html, /Hi ann&lt;x&gt;,/);
  assert.match(v.html, /href="https:\/\/api\.x\/auth\/verify-email\?token=abc&amp;a=1"/);
  assert.ok(!/\{\{/.test(v.html));
  assert.equal(v.subject, 'Verify your XP GasTech email');
  process.env.EMAIL_VERIFY_SUBJECT = 'Custom';
  process.env.EMAIL_VERIFY_HTML = '<b>{{name}}|{{link}}</b>';
  const c = mailer.verificationEmail({ email: 'bob@b.co', link: 'L' });
  assert.equal(c.subject, 'Custom');
  assert.equal(c.html, '<b>bob|L</b>');
  const w = mailer.welcomeEmail({ email: 'bob@b.co' });
  assert.match(w.html, /Hi bob,/);
  assert.match(w.html, /https:\/\/xptechltd\.com/);
});

test('SMS OTP text: default is exactly the original; env template customizes', () => {
  const { buildOtpMessage } = require('../src/services/smsAuth');
  assert.equal(buildOtpMessage('123456'), 'Your XP GasTech verification code is 123456. It expires in 10 minutes.');
  process.env.SMS_OTP_TEMPLATE = 'XP: {{code}} is your code';
  assert.equal(buildOtpMessage('123456'), 'XP: 123456 is your code');
  process.env.SMS_OTP_TEMPLATE = 'no placeholder here';
  assert.equal(buildOtpMessage('123456'), 'Your XP GasTech verification code is 123456. It expires in 10 minutes.');
});

test('signup: no token, stores only hash, emails link', async () => {
  configure();
  setDb((sql) => (/insert into users/.test(sql) ? { rows: [{ id: 'u1', email: 'a@b.co', phone: null }] } : { rows: [] }));
  const r = await auth.signup({ email: 'A@B.co', password: 'password123' });
  assert.equal(r.verificationRequired, true);
  assert.equal(r.message, 'Check your email to verify your account');
  assert.equal(r.token, undefined);
  assert.equal(mails.length, 1);
  assert.deepEqual(mails[0].payload.to, [{ email: 'a@b.co', name: 'a' }]);
  const m = mails[0].payload.message_body.value.match(/token=([0-9a-f]{64})/);
  assert.ok(m, 'link with 64-hex token');
  const ins = queries.find((q) => /insert into email_verification_tokens/.test(q.sql));
  assert.equal(ins.params[1], sha(m[1]));
  assert.ok(!queries.some((q) => q.params.includes(m[1])), 'raw token never sent to DB');
  const exp = new Date(ins.params[2]).getTime() - Date.now();
  assert.ok(exp > 23.9 * 3600e3 && exp <= 24 * 3600e3);
});

test('signup without email config still creates user and warns', async () => {
  setDb((sql) => (/insert into users/.test(sql) ? { rows: [{ id: 'u1', email: 'a@b.co', phone: null }] } : { rows: [] }));
  const r = await auth.signup({ email: 'a@b.co', password: 'password123' });
  assert.equal(r.verificationRequired, true);
  assert.equal(r.emailSent, false);
  assert.match(r.message, /couldn't send/);
  assert.equal(mails.length, 0);
});

test('signup survives provider failure; duplicate -> 409', async () => {
  configure();
  mailer.setTransport(async () => ({ status: 500, text: '' }));
  setDb((sql) => (/insert into users/.test(sql) ? { rows: [{ id: 'u1', email: 'a@b.co', phone: null }] } : { rows: [] }));
  const r = await auth.signup({ email: 'a@b.co', password: 'password123' });
  assert.equal(r.emailSent, false);
  setDb(() => { const e = new Error('dup'); e.code = '23505'; throw e; });
  await assert.rejects(auth.signup({ email: 'a@b.co', password: 'password123' }), { status: 409 });
});

test('login: unverified -> 403 EMAIL_NOT_VERIFIED; verified -> token', async () => {
  const bcrypt = require('bcryptjs');
  const hash = await bcrypt.hash('password123', 4);
  setDb(() => ({ rows: [{ id: 'u1', email: 'a@b.co', phone: null, password_hash: hash, email_verified_at: null }] }));
  await assert.rejects(auth.login({ email: 'a@b.co', password: 'password123' }), { status: 403, code: 'EMAIL_NOT_VERIFIED', message: 'Please verify your email first' });
  await assert.rejects(auth.login({ email: 'a@b.co', password: 'wrong-password' }), { status: 401 });
  setDb(() => ({ rows: [{ id: 'u1', email: 'a@b.co', phone: null, password_hash: hash, email_verified_at: new Date() }] }));
  const ok = await auth.login({ email: 'a@b.co', password: 'password123' });
  assert.ok(ok.token);
});

test('verifyEmailToken: rejects malformed, hashes valid, sends welcome best-effort', async () => {
  assert.deepEqual(await auth.verifyEmailToken('nope'), { ok: false });
  assert.deepEqual(await auth.verifyEmailToken(undefined), { ok: false });
  const token = crypto.randomBytes(32).toString('hex');
  setDb(() => ({ rows: [{ id: 'u1', email: 'a@b.co' }] }));
  configure();
  mailer.setTransport(async (a) => { mails.push(a); throw new Error('welcome fails'); });
  const r = await auth.verifyEmailToken(token);
  assert.equal(r.ok, true);
  assert.equal(queries[0].params[0], sha(token));
  assert.match(queries[0].sql, /used_at is null and expires_at > now\(\)/);
  assert.equal(mails.length, 1);
});

test('verifyEmailToken: unknown/expired/used -> ok false', async () => {
  setDb(() => ({ rows: [] }));
  assert.deepEqual(await auth.verifyEmailToken(crypto.randomBytes(32).toString('hex')), { ok: false });
});

test('resendVerification: generic response, only sends for unverified, cooldown', async () => {
  configure();
  const generic = (r) => assert.equal(r.ok, true);
  setDb(() => ({ rows: [] }));
  generic(await auth.resendVerification('nobody@b.co'));
  assert.equal(mails.length, 0);
  setDb((sql) => (/from users u/.test(sql) ? { rows: [{ id: 'u1', email: 'a@b.co', email_verified_at: new Date(), password_hash: 'x', last_sent: null }] } : { rows: [] }));
  generic(await auth.resendVerification('a@b.co'));
  assert.equal(mails.length, 0);
  setDb((sql) => (/from users u/.test(sql) ? { rows: [{ id: 'u1', email: 'a@b.co', email_verified_at: null, password_hash: 'x', last_sent: new Date() }] } : { rows: [] }));
  generic(await auth.resendVerification('a@b.co'));
  assert.equal(mails.length, 0);
  setDb((sql) => (/from users u/.test(sql) ? { rows: [{ id: 'u1', email: 'a@b.co', email_verified_at: null, password_hash: 'x', last_sent: new Date(Date.now() - 5 * 60e3) }] } : { rows: [] }));
  const a = await auth.resendVerification('a@b.co');
  generic(a);
  assert.equal(mails.length, 1);
  setDb(() => { throw new Error('db down'); });
  generic(await auth.resendVerification('a@b.co'));
  await assert.rejects(auth.resendVerification('not-an-email'), { status: 400 });
});

async function withServer(fn) {
  const { app } = require('../server');
  const srv = app.listen(0);
  try { await fn(`http://127.0.0.1:${srv.address().port}`); } finally { srv.close(); }
}

test('routes: GET verify-email renders success/failure HTML; resend is generic; login 403 body has code', async () => {
  await withServer(async (base) => {
    const token = crypto.randomBytes(32).toString('hex');
    setDb(() => ({ rows: [{ id: 'u1', email: 'a@b.co' }] }));
    let r = await fetch(`${base}/auth/verify-email?token=${token}`);
    assert.equal(r.status, 200);
    assert.match(await r.text(), /Email verified[\s\S]*https:\/\/xptechltd\.com/);
    setDb(() => ({ rows: [] }));
    r = await fetch(`${base}/auth/verify-email?token=${token}`);
    assert.equal(r.status, 400);
    assert.match(await r.text(), /invalid, already used, or expired/);
    r = await fetch(`${base}/auth/resend-verification`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email: 'x@y.co' }) });
    assert.equal(r.status, 200);
    assert.equal((await r.json()).ok, true);
    const bcrypt = require('bcryptjs');
    const hash = await bcrypt.hash('password123', 4);
    setDb(() => ({ rows: [{ id: 'u1', email: 'a@b.co', password_hash: hash, email_verified_at: null }] }));
    r = await fetch(`${base}/auth/login`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email: 'a@b.co', password: 'password123' }) });
    assert.equal(r.status, 403);
    assert.deepEqual(await r.json(), { error: 'Please verify your email first', code: 'EMAIL_NOT_VERIFIED' });
    r = await fetch(`${base}/health`);
    assert.equal((await r.json()).emailConfigured, false);
  });
});
