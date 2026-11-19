const SMS_ENDPOINT = 'https://api.sendchamp.com/api/v1/sms/send';
const DEFAULT_SENDER_NAME = 'Sendchamp';
const DEFAULT_ROUTE = 'DND_NG';
const VALID_ROUTES = new Set(['DND_NG', 'NON_DND_NG', 'PREMIUM_NG']);

function getSmsConfig() {
  const publicKey = (process.env.SENDCHAMP_PUBLIC_KEY || '').trim();
  const senderName = (process.env.SENDCHAMP_SENDER_NAME || '').trim() || DEFAULT_SENDER_NAME;
  const requestedRoute = (process.env.SENDCHAMP_ROUTE || '').trim().toUpperCase();
  const route = VALID_ROUTES.has(requestedRoute) ? requestedRoute : DEFAULT_ROUTE;
  return { publicKey, senderName, route, configured: Boolean(publicKey) };
}

function smsError(message, code, status, providerResponse) {
  const err = new Error(message);
  err.code = code;
  err.status = status;
  if (providerResponse !== undefined) err.providerResponse = providerResponse;
  return err;
}

// Sendchamp wants international format without the leading '+'.
function toSendchampNumber(n) {
  return String(n).trim().replace(/^\+/, '');
}

// Keep only non-sensitive fields of the provider reply for logs/debugging.
function summarize(payload) {
  if (!payload || typeof payload !== 'object') return undefined;
  return { status: payload.status, code: payload.code, message: payload.message };
}

function httpsPost(url, key, data) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = require('https').request(
      {
        method: 'POST',
        hostname: u.hostname,
        path: u.pathname,
        timeout: 15000,
        headers: {
          Authorization: `Bearer ${key}`,
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

/**
 * Send an SMS through Sendchamp.
 * @param {string|string[]} to one E.164 number (+234...) or an array of them (bulk)
 * @param {string} body message text
 */
async function sendSms(to, body) {
  const { publicKey, senderName, route, configured } = getSmsConfig();
  if (!configured) {
    throw smsError(
      'SMS is not configured. Set SENDCHAMP_PUBLIC_KEY.',
      'SMS_NOT_CONFIGURED',
      503
    );
  }

  const recipients = (Array.isArray(to) ? to : [to]).map(toSendchampNumber).filter(Boolean);
  if (recipients.length === 0) {
    throw smsError('No SMS recipient provided.', 'SMS_SEND_FAILED', 400);
  }

  let response;
  let payload;
  try {
    response = await fetch(SMS_ENDPOINT, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${publicKey}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify({ to: recipients, message: body, sender_name: senderName, route }),
    });
    const text = await response.text();
    try {
      payload = JSON.parse(text);
    } catch (_) {
      payload = undefined;
    }
  } catch (err) {
    console.error(
      '[sendchamp] fetch failed:',
      err && err.name,
      err && err.message,
      err && err.cause && (err.cause.code || err.cause.message)
    );
    try {
      console.error('[sendchamp] inspect', require('util').inspect(err && err.cause, { depth: 3 }).slice(0, 1500));
    } catch (_) {}
    console.error('[sendchamp] key diag', {
      len: publicKey.length,
      printableAscii: /^[\x21-\x7E]+$/.test(publicKey),
    });
    try {
      const r = await httpsPost(SMS_ENDPOINT, publicKey, JSON.stringify({ to: recipients, message: body, sender_name: senderName, route }));
      console.error('[sendchamp] https fallback status', r.status);
      response = { ok: r.status >= 200 && r.status < 300, status: r.status };
      try { payload = JSON.parse(r.text); } catch (_) { payload = undefined; }
    } catch (e3) {
      console.error('[sendchamp] https fallback failed', e3 && e3.code, e3 && e3.message);
      throw smsError('Could not reach the SMS provider.', 'SMS_SEND_FAILED', 502);
    }
  }

  if (!response.ok || !payload || String(payload.status).toLowerCase() !== 'success') {
    console.error('[sendchamp] non-ok response:', response.status, JSON.stringify(summarize(payload)));
    throw smsError('The SMS provider rejected the request.', 'SMS_SEND_FAILED', 502, summarize(payload));
  }
  return payload;
}

module.exports = { getSmsConfig, sendSms, SMS_ENDPOINT };
