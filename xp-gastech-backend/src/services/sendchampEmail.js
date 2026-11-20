const fs = require('fs');
const path = require('path');
const https = require('https');
const { getSmsConfig } = require('./sendchamp');

const EMAIL_HOST = 'api.sendchamp.com';
const EMAIL_PATH = '/api/v1/email/send';
const DEFAULT_FROM_NAME = 'XP Tech';
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

// Sendchamp/Go54 delivers every /email/send message as text/plain (confirmed
// in Gmail raw source for both type "text/html" and type "html"). HTML is
// shown as visible tags, so we send a clean plain-text body.
function htmlToText(html) {
  return String(html || '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/p>/gi, '\n\n')
    .replace(/<a [^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi, (_, href, label) => {
      const t = label.replace(/<[^>]+>/g, '').trim();
      return t && t !== href ? `${t} (${href})` : href;
    })
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&mdash;/g, '\u2014')
    .replace(/&middot;/g, '\u00b7')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/**
 * Send one email through Sendchamp. Throws EMAIL_NOT_CONFIGURED / EMAIL_SEND_FAILED.
 * Never logs the key or the message body.
 * @param {{to: string, name?: string, subject: string, html?: string, text?: string}} msg
 */
async function sendEmail({ to, name, subject, html, text }) {
  const { apiKey, fromEmail, fromName, configured } = getEmailConfig();
  if (!configured) {
    throw emailError('Email is not configured. Set SENDCHAMP_PUBLIC_KEY and SENDCHAMP_EMAIL_FROM.', 'EMAIL_NOT_CONFIGURED');
  }
  const value = (text && String(text).trim()) || htmlToText(html);
  const payload = {
    subject,
    to: [{ email: to, name: name || to }],
    from: { email: fromEmail, name: fromName },
    message_body: { type: 'text', value },
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

// Plain-text placeholder replacement (no HTML escaping).
function renderText(template, vars) {
  return String(template).replace(/\{\{\s*([a-z_]+)\s*\}\}/gi, (_, k) => (vars[k] === undefined ? '' : String(vars[k])));
}

// Friendly name for greetings: the given name if we have one (e.g. from
// Google), otherwise the part of the email before the @.
function displayName(email, name) {
  const given = String(name || '').trim().replace(/\s+/g, ' ').slice(0, 60);
  if (given) return given;
  const local = String(email || '').split('@')[0];
  return local || 'there';
}

const DEFAULT_VERIFY_TEXT = `XP Tech

Confirm your email, {{name}}

Thanks for signing up for XP Tech. We're glad you're here.

Please confirm your email to activate your account by opening this link (it expires in 24 hours):

{{link}}

Didn't sign up for XP Tech? You can safely ignore this email — no account will be activated.

We look forward to helping you keep an eye on your cooking gas.

Warmly,
The XP Tech team

Safety first: if you ever smell gas, leave the area right away and call 112 from a safe place.

XP Tech Ltd · Enugu, Nigeria
Questions? support@xptechltd.com
`;

const DEFAULT_WELCOME_TEXT = `XP Tech

Welcome to XP Tech, {{name}}

Your account is ready. We're so glad to have you. XP Tech keeps an eye on your cooking gas so you never run out by surprise.

Here's what you can do:
- Live gas level — see how much gas is left in your cylinder
- Low-gas alerts — get a heads-up before you run out
- Nearby refill — find gas retailers close to you
- Usage history — track how fast you use gas over time

Get started in 3 steps:
1. Connect your meter — turn on Bluetooth and pair your XP meter in the app.
2. Set your cylinder size — so your gas level and days left are accurate.
3. Turn on alerts — allow notifications to hear about low gas in time.

Open XP Tech: {{app_url}}

Need help setting up? Write to support@xptechltd.com.

Welcome to the family. If you ever need anything, just write to us.

Warmly,
The XP Tech team

Safety first: if you ever smell gas, leave the area right away and call 112 from a safe place.

XP Tech Ltd · Enugu, Nigeria
Questions? support@xptechltd.com
`;

/**
 * Overridable via env: EMAIL_VERIFY_SUBJECT, EMAIL_VERIFY_HTML (full HTML with
 * {{name}} {{link}} {{app_url}}), EMAIL_VERIFY_TEXT, EMAIL_WELCOME_SUBJECT,
 * EMAIL_WELCOME_HTML, EMAIL_WELCOME_TEXT.
 */
function verificationEmail({ email, link, name: givenName }) {
  const { appBaseUrl } = getEmailConfig();
  const name = displayName(email, givenName);
  const vars = { name, link, app_url: appBaseUrl };
  const tpl = loadTemplate(
    'verification.html',
    'EMAIL_VERIFY_HTML',
    '<p>Hi {{name}}, verify your email for XP Tech: <a href="{{link}}">{{link}}</a></p>'
  );
  const textTpl = (process.env.EMAIL_VERIFY_TEXT || '').trim() || DEFAULT_VERIFY_TEXT;
  const subject = (process.env.EMAIL_VERIFY_SUBJECT || '').trim() || 'Verify your email for XP Tech';
  return { name, subject, html: render(tpl, vars), text: renderText(textTpl, vars) };
}

function welcomeEmail({ email, name: givenName }) {
  const { appBaseUrl } = getEmailConfig();
  const name = displayName(email, givenName);
  const vars = { name, app_url: appBaseUrl };
  const tpl = loadTemplate(
    'welcome.html',
    'EMAIL_WELCOME_HTML',
    '<p>Welcome to XP Tech, {{name}}. <a href="{{app_url}}">Open XP Tech</a></p>'
  );
  const textTpl = (process.env.EMAIL_WELCOME_TEXT || '').trim() || DEFAULT_WELCOME_TEXT;
  const subject = (process.env.EMAIL_WELCOME_SUBJECT || '').trim() || `Welcome to XP Tech, ${name}`;
  return { name, subject, html: render(tpl, vars), text: renderText(textTpl, vars) };
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
  htmlToText,
};
