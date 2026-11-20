const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');

// Load from api-v4
const verify = require('../src/services/sendchampVerify');

const saved = {};
test.beforeEach(() => {
  for (const k of ['SENDCHAMP_PUBLIC_KEY', 'SENDCHAMP_OTP_SENDER']) {
    saved[k] = process.env[k];
    delete process.env[k];
  }
  verify.setTransport(null);
});
test.afterEach(() => {
  verify.setTransport(null);
  for (const k of Object.keys(saved)) {
    if (saved[k] === undefined) delete process.env[k];
    else process.env[k] = saved[k];
  }
});

test('getOtpConfig defaults sender to Sendchamp', () => {
  process.env.SENDCHAMP_PUBLIC_KEY = 'k';
  const c = verify.getOtpConfig();
  assert.equal(c.configured, true);
  assert.equal(c.sender, 'Sendchamp');
  process.env.SENDCHAMP_OTP_SENDER = 'XPTech';
  assert.equal(verify.getOtpConfig().sender, 'XPTech');
});

test('createVerification posts the right payload and returns the reference', async () => {
  process.env.SENDCHAMP_PUBLIC_KEY = 'secret-key-123';
  const calls = [];
  verify.setTransport(async (args) => {
    calls.push(args);
    return { status: 200, text: JSON.stringify({ status: 'success', code: 200, data: { reference: 'MN-OTP-abc', status: 'sent' } }) };
  });
  const out = await verify.createVerification({ phone: '+2348118514863' });
  assert.equal(out.reference, 'MN-OTP-abc');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].path, '/api/v1/verification/create');
  assert.equal(calls[0].apiKey, 'secret-key-123');
  assert.deepEqual(calls[0].payload, {
    channel: 'sms',
    sender: 'Sendchamp',
    token_type: 'numeric',
    token_length: 6,
    expiration_time: 10,
    customer_mobile_number: '2348118514863',
    meta_data: { first_name: 'XPTech' },
  });
});

test('confirmVerification posts reference+code and maps invalid token to OTP_INVALID', async () => {
  process.env.SENDCHAMP_PUBLIC_KEY = 'k';
  verify.setTransport(async () => ({
    status: 400,
    text: JSON.stringify({ status: 'failed', code: 400, message: 'invalid token' }),
  }));
  await assert.rejects(verify.confirmVerification({ reference: 'MN-OTP-abc', code: '000000' }), (err) => {
    assert.equal(err.code, 'OTP_INVALID');
    assert.equal(err.status, 401);
    return true;
  });
});

test('confirmVerification succeeds on 200 success', async () => {
  process.env.SENDCHAMP_PUBLIC_KEY = 'k';
  verify.setTransport(async (args) => {
    assert.equal(args.path, '/api/v1/verification/confirm');
    assert.deepEqual(args.payload, { verification_reference: 'MN-OTP-abc', verification_code: '123456' });
    return { status: 200, text: JSON.stringify({ status: 'success', code: 200, message: 'Confirm verification' }) };
  });
  assert.equal(await verify.confirmVerification({ reference: 'MN-OTP-abc', code: '123456' }), true);
});

test('createVerification not configured', async () => {
  await assert.rejects(verify.createVerification({ phone: '+2348012345678' }), { code: 'OTP_NOT_CONFIGURED' });
});
