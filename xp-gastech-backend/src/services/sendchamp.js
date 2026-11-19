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
  } catch (_) {
    throw smsError('Could not reach the SMS provider.', 'SMS_SEND_FAILED', 502);
  }

  if (!response.ok || !payload || String(payload.status).toLowerCase() !== 'success') {
    throw smsError('The SMS provider rejected the request.', 'SMS_SEND_FAILED', 502, summarize(payload));
  }
  return payload;
}

module.exports = { getSmsConfig, sendSms, SMS_ENDPOINT };
