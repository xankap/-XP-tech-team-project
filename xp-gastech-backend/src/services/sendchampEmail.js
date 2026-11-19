const fs = require('fs');
const path = require('path');
const https = require('https');
const { getSmsConfig } = require('./sendchamp');

const EMAIL_HOST = 'api.sendchamp.com';
const EMAIL_PATH = '/api/v1/email/send';
const DEFAULT_FROM_NAME = 'XP GasTech';
const DEFAULT_API_BASE = 'https://api.xptechltd.com';
const DEFAULT_APP_BASE = 'https://xptechltd.com';

function stripSlash(v) {
  return String(v).replace(/\/+$/, '');
}

/**
 * Email goes through Sendchamp's Email API using the same SENDCHAMP_PUBLIC_KEY as SMS.
 * Configured = key present AND SENDCHAMP_EMAIL_FROM set.
 */
function getEmailConfig() {
  const apiKey = getSmsConfig().publicKey;
  const fromEmail = (process.env.SENDCHAMP_EMAIL_FROM || '').trim();
  const fromName = (process.env.SENDCHAMP_EMAIL_FROM_NAME || '').trim() || DEFAULT_FROM_NAME;
  const apiBaseUrl = stripSlash((process.env.API_BASE_URL || '').trim() || DEFAULT_API_BASE);
  const appBaseUrl = stripSlash((process.env.APP_BASE_URL || '').trim() || DEFAULT_APP_BASE);
  return { apiKey, fromEmail, fromName, apiBaseUrl, appBaseUrl, configured: Boolean(apiKey && fromEmail) };
}

// Plain https.request transport (fetch-with-body is unreliable on the Vercel runtime).
function defaultTransport({ apiKey, payload }) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(payload);
    const req = https.request(
      {
        method: 'POST',
        hostname: EMAIL_HOST,
        path: EMAIL_PATH,
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

function emailError(message, code, providerResponse) {
  const err = new Error(message);
  err.code = code;
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

/**
 * Send one email through Sendchamp. Throws EMAIL_NOT_CONFIGURED / EMAIL_SEND_FAILED.
 * Never logs the key or the message body.
 * @param {{to: string, name?: string, subject: string, html: string}} msg
 */
async function sendEmail({ to, name, subject, html }) {
  const { apiKey, fromEmail, fromName, configured } = getEmailConfig();
  if (!configured) {
    throw emailError('Email is not configured. Set SENDCHAMP_PUBLIC_KEY and SENDCHAMP_EMAIL_FROM.', 'EMAIL_NOT_CONFIGURED');
  }
  const payload = {
    subject,
    to: [{ email: to, name: name || to }],
    from: { email: fromEmail, name: fromName },
    message_body: { type: 'text/html', value: html },
  };
  let res;
  try {
    res = await transport({ apiKey, payload });
  } catch (e) {
    console.error('[sendchamp-email] request failed:', e && e.code, e && e.message);
    throw emailError('Could not reach the email provider.', 'EMAIL_SEND_FAILED');
  }
  const summary = summarize(res && res.text);
  const failedBody = summary && String(summary.status).toLowerCase() === 'failed';
  if (!res || res.status < 200 || res.status >= 300 || failedBody) {
    console.error('[sendchamp-email] provider rejected:', res && res.status, JSON.stringify(summary));
    throw emailError('The email provider rejected the request.', 'EMAIL_SEND_FAILED', summary);
  }
  return true;
}

// ---- templates -------------------------------------------------------------

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function layout(title, bodyHtml) {
  return `<!doctype html><html><body style="margin:0;background:#f4f6f8;font-family:Arial,Helvetica,sans-serif;color:#1a1a1a">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" style="padding:24px">
<table role="presentation" width="480" cellspacing="0" cellpadding="0" style="background:#ffffff;border-radius:8px;padding:32px;max-width:480px">
<tr><td><h2 style="margin:0 0 16px;color:#0b6b3a">XP GasTech</h2><h3 style="margin:0 0 12px">${esc(title)}</h3>${bodyHtml}</td></tr></table></td></tr></table></body></html>`;
}

function loadTemplate(file, envName, fallback) {
  const fromEnv = (process.env[envName] || '').trim();
  if (fromEnv) return fromEnv;
  try {
    return fs.readFileSync(path.join(__dirname, '..', 'templates', file), 'utf8');
  } catch (e) {
    console.error('[sendchamp-email] template load failed:', file, e && e.code);
    return fallback;
  }
}

// Replace {{placeholders}}; values are HTML-escaped. Unknown placeholders become ''.
function render(template, vars) {
  return String(template).replace(/\{\{\s*([a-z_]+)\s*\}\}/gi, (_, k) => (vars[k] === undefined ? '' : esc(vars[k])));
}

function displayName(email) {
  const local = String(email || '').split('@')[0];
  return local || 'there';
}

/**
 * Overridable via env: EMAIL_VERIFY_SUBJECT, EMAIL_VERIFY_HTML (full HTML with
 * {{name}} {{link}} {{app_url}}), EMAIL_WELCOME_SUBJECT, EMAIL_WELCOME_HTML.
 */
function verificationEmail({ email, link }) {
  const { appBaseUrl } = getEmailConfig();
  const tpl = loadTemplate(
    'verification.html',
    'EMAIL_VERIFY_HTML',
    '<p>Hi {{name}}, verify your email: <a href="{{link}}">{{link}}</a></p>'
  );
  const subject = (process.env.EMAIL_VERIFY_SUBJECT || '').trim() || 'Verify your XP GasTech email';
  return { name: displayName(email), subject, html: render(tpl, { name: displayName(email), link, app_url: appBaseUrl }) };
}

function welcomeEmail({ email }) {
  const { appBaseUrl } = getEmailConfig();
  const tpl = loadTemplate(
    'welcome.html',
    'EMAIL_WELCOME_HTML',
    '<p>Hi {{name}}, welcome to XP GasTech. <a href="{{app_url}}">Open the app</a></p>'
  );
  const subject = (process.env.EMAIL_WELCOME_SUBJECT || '').trim() || 'Welcome to XP GasTech';
  return { name: displayName(email), subject, html: render(tpl, { name: displayName(email), app_url: appBaseUrl }) };
}

module.exports = {
  getEmailConfig,
  sendEmail,
  setTransport,
  verificationEmail,
  welcomeEmail,
  render,
  esc,
  layout,
};
