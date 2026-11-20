const https = require('https');
const { getSmsConfig } = require('./sendchamp');

const VERIFY_HOST = 'api.sendchamp.com';
const CREATE_PATH = '/api/v1/verification/create';
const CONFIRM_PATH = '/api/v1/verification/confirm';
const DEFAULT_OTP_SENDER = 'Sendchamp';
const TOKEN_LENGTH = 6;
const EXPIRATION_MINUTES = 10;

/**
 * OTP sender is independent of SENDCHAMP_SENDER_NAME (the SMS API sender).
 * The Verification API accepts "Sendchamp"; the SMS send API may not.
 */
function getOtpConfig() {
  const { publicKey, configured } = getSmsConfig();
  const sender = (process.env.SENDCHAMP_OTP_SENDER || '').trim() || DEFAULT_OTP_SENDER;
  return { publicKey, sender, configured };
}

function toSendchampNumber(n) {
  return String(n).trim().replace(/^\+/, '');
}

function otpError(message, code, status, providerResponse) {
  const err = new Error(message);
  err.code = code;
  err.status = status;
  if (providerResponse !== undefined) err.providerResponse = providerResponse;
  return err;
}

function summarize(text) {
  try {
    const p = JSON.parse(text);
    if (p && typeof p === 'object') return { status: p.status, code: p.code, message: p.message };
  } catch (_) {}
  return undefined;
}

function defaultTransport({ apiKey, path, payload }) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(payload);
    const req = https.request(
      {
        method: 'POST',
        hostname: VERIFY_HOST,
        path,
        timeout: 15000,
        headers: {
          Authorization: `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
          Accept: 'application/json',
          'Content-Length': Buffer.byteLength(data),
        },
      },
      (res) => {
        let text = '';
        res.on('data', (d) => (text += d));
        res.on('end', () => resolve({ status: res.statusCode, text }));
      }
    );
    req.on('timeout', () => req.destroy(Object.assign(new Error('timeout'), { code: 'ETIMEDOUT' })));
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

let transport = defaultTransport;
function setTransport(fn) {
  transport = fn || defaultTransport;
}

function failed(res, summary) {
  const failedBody = summary && String(summary.status).toLowerCase() === 'failed';
  const errStatus = summary && String(summary.status).toLowerCase() === 'error';
  return !res || res.status < 200 || res.status >= 300 || failedBody || errStatus;
}

/**
 * Create a 6-digit SMS OTP via Sendchamp Verification. Returns { reference }.
 * Never logs the key or the token.
 */
async function createVerification({ phone }) {
  const { publicKey, sender, configured } = getOtpConfig();
  if (!configured) {
    throw otpError('SMS is not configured. Set SENDCHAMP_PUBLIC_KEY.', 'OTP_NOT_CONFIGURED', 503);
  }
  const apiKey = publicKey;
  const payload = {
    channel: 'sms',
    sender,
    token_type: 'numeric',
    token_length: TOKEN_LENGTH,
    expiration_time: EXPIRATION_MINUTES,
    customer_mobile_number: toSendchampNumber(phone),
    meta_data: { first_name: 'XPTech' },
  };
  let res;
  try {
    res = await transport({ apiKey, path: CREATE_PATH, payload });
  } catch (e) {
    console.error('[sendchamp-otp] create failed:', e && e.code, e && e.message);
    throw otpError('Could not reach the verification provider.', 'OTP_SEND_FAILED', 502);
  }
  const summary = summarize(res && res.text);
  if (failed(res, summary)) {
    console.error('[sendchamp-otp] create rejected:', res && res.status, JSON.stringify(summary));
    throw otpError('The verification provider rejected the request.', 'OTP_SEND_FAILED', 502, summary);
  }
  let reference;
  try {
    const body = JSON.parse(res.text);
    reference = body && body.data && body.data.reference;
  } catch (_) {}
  if (!reference || typeof reference !== 'string') {
    throw otpError('The verification provider did not return a reference.', 'OTP_SEND_FAILED', 502);
  }
  return { reference };
}

/**
 * Confirm a previously created OTP. Throws OTP_INVALID (401) or OTP_EXPIRED (400)
 * for expected failures; OTP_CONFIRM_FAILED (502) otherwise.
 */
async function confirmVerification({ reference, code }) {
  const { publicKey, configured } = getOtpConfig();
  if (!configured) {
    throw otpError('SMS is not configured. Set SENDCHAMP_PUBLIC_KEY.', 'OTP_NOT_CONFIGURED', 503);
  }
  const payload = {
    verification_reference: String(reference),
    verification_code: String(code),
  };
  let res;
  try {
    res = await transport({ apiKey: publicKey, path: CONFIRM_PATH, payload });
  } catch (e) {
    console.error('[sendchamp-otp] confirm failed:', e && e.code, e && e.message);
    throw otpError('Could not reach the verification provider.', 'OTP_CONFIRM_FAILED', 502);
  }
  const summary = summarize(res && res.text);
  if (!failed(res, summary)) return true;

  const msg = String((summary && summary.message) || '').toLowerCase();
  if (msg.includes('invalid') || msg.includes('incorrect') || msg.includes('wrong') || res.status === 400) {
    if (msg.includes('expir')) {
      throw otpError('Code expired. Request a new one.', 'OTP_EXPIRED', 400, summary);
    }
    throw otpError('Invalid code', 'OTP_INVALID', 401, summary);
  }
  if (msg.includes('expir') || msg.includes('not found') || msg.includes('already')) {
    throw otpError('Code expired. Request a new one.', 'OTP_EXPIRED', 400, summary);
  }
  console.error('[sendchamp-otp] confirm rejected:', res && res.status, JSON.stringify(summary));
  throw otpError('The verification provider rejected the request.', 'OTP_CONFIRM_FAILED', 502, summary);
}

module.exports = {
  getOtpConfig,
  createVerification,
  confirmVerification,
  setTransport,
  toSendchampNumber,
  TOKEN_LENGTH,
  EXPIRATION_MINUTES,
};
