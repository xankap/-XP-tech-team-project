const test = require('node:test');
const assert = require('node:assert/strict');
const { sendSms, getSmsConfig, SMS_ENDPOINT } = require('../src/services/sendchamp');

const ENV_KEYS = ['SENDCHAMP_PUBLIC_KEY', 'SENDCHAMP_SENDER_NAME', 'SENDCHAMP_ROUTE'];
const realFetch = global.fetch;
const savedEnv = {};

test.beforeEach(() => {
  for (const k of ENV_KEYS) { savedEnv[k] = process.env[k]; delete process.env[k]; }
});
test.afterEach(() => {
  global.fetch = realFetch;
  for (const k of ENV_KEYS) {
    if (savedEnv[k] === undefined) delete process.env[k]; else process.env[k] = savedEnv[k];
  }
});

function mockFetch(status, body) {
  const calls = [];
  global.fetch = async (url, init) => {
    calls.push({ url, init });
    return { ok: status >= 200 && status < 300, status, text: async () => (typeof body === 'string' ? body : JSON.stringify(body)) };
  };
  return calls;
}

test('config defaults', () => {
  process.env.SENDCHAMP_PUBLIC_KEY = 'k';
  const c = getSmsConfig();
  assert.equal(c.configured, true);
  assert.equal(c.senderName, 'Sendchamp');
  assert.equal(c.route, 'DND_NG');
});

test('config reads overrides and ignores invalid route', () => {
  process.env.SENDCHAMP_PUBLIC_KEY = 'k';
  process.env.SENDCHAMP_SENDER_NAME = 'XPGasTech';
  process.env.SENDCHAMP_ROUTE = 'bogus';
  const c = getSmsConfig();
  assert.equal(c.senderName, 'XPGasTech');
  assert.equal(c.route, 'DND_NG');
  process.env.SENDCHAMP_ROUTE = 'non_dnd_ng';
  assert.equal(getSmsConfig().route, 'NON_DND_NG');
});

test('success: sends correct request', async () => {
  process.env.SENDCHAMP_PUBLIC_KEY = 'secret-key-123';
  const calls = mockFetch(200, { status: 'success', code: 200, data: { status: 'processing' } });
  const out = await sendSms('+2348012345678', 'hi');
  assert.equal(out.status, 'success');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, SMS_ENDPOINT);
  assert.equal(calls[0].init.method, 'POST');
  assert.equal(calls[0].init.headers.Authorization, 'Bearer secret-key-123');
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    to: ['2348012345678'], message: 'hi', sender_name: 'Sendchamp', route: 'DND_NG',
  });
});

test('success: accepts an array of numbers', async () => {
  process.env.SENDCHAMP_PUBLIC_KEY = 'k';
  const calls = mockFetch(200, { status: 'success' });
  await sendSms(['+2348011111111', '2348022222222'], 'bulk');
  assert.deepEqual(JSON.parse(calls[0].init.body).to, ['2348011111111', '2348022222222']);
});

test('provider failure: non-2xx -> 502 without leaking key', async () => {
  process.env.SENDCHAMP_PUBLIC_KEY = 'secret-key-123';
  mockFetch(400, { status: 'error', code: 400, message: 'To required' });
  await assert.rejects(sendSms('+2348012345678', 'hi'), (err) => {
    assert.equal(err.code, 'SMS_SEND_FAILED');
    assert.equal(err.status, 502);
    assert.ok(!JSON.stringify(err).includes('secret-key-123'));
    assert.ok(!err.message.includes('secret-key-123'));
    return true;
  });
});

test('provider failure: 200 but status != success -> 502', async () => {
  process.env.SENDCHAMP_PUBLIC_KEY = 'k';
  mockFetch(200, { status: 'error', message: 'insufficient balance' });
  await assert.rejects(sendSms('+2348012345678', 'hi'), (err) => err.status === 502 && err.code === 'SMS_SEND_FAILED');
});

test('provider failure: non-JSON body and network error -> 502', async () => {
  process.env.SENDCHAMP_PUBLIC_KEY = 'k';
  mockFetch(200, '<html>oops</html>');
  await assert.rejects(sendSms('+2348012345678', 'hi'), (err) => err.status === 502);
  global.fetch = async () => { throw new Error('ECONNRESET'); };
  await assert.rejects(sendSms('+2348012345678', 'hi'), (err) => err.status === 502 && err.code === 'SMS_SEND_FAILED');
});

test('not configured -> 503 and no fetch', async () => {
  const calls = mockFetch(200, { status: 'success' });
  await assert.rejects(sendSms('+2348012345678', 'hi'), (err) => err.code === 'SMS_NOT_CONFIGURED' && err.status === 503);
  assert.equal(calls.length, 0);
});
