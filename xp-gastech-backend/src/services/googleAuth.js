const { OAuth2Client } = require('google-auth-library');
const { pool } = require('../db/pool');
const { publicUser } = require('./emailAuth');
const { issueSession } = require('./sessions');
const { getEmailConfig, sendEmail, welcomeEmail } = require('./sendchampEmail');

// Longest we hold the login response for the welcome email. Sending is
// best-effort: errors are logged and never fail or block sign-in.
const WELCOME_WAIT_MS = 2500;

async function sendGoogleWelcome(email, name) {
  try {
    if (!getEmailConfig().configured) return;
    const send = sendEmail({ to: email, ...welcomeEmail({ email, name }) }).catch((e) => {
      console.error('[google] welcome email failed:', e && e.code);
    });
    let timer;
    await Promise.race([send, new Promise((r) => { timer = setTimeout(r, WELCOME_WAIT_MS); })]);
    clearTimeout(timer);
  } catch (e) {
    console.error('[google] welcome email failed:', e && e.code);
  }
}

function getGoogleClientId() {
  return (process.env.GOOGLE_CLIENT_ID || '').trim();
}

async function loginWithGoogleIdToken(idToken, ctx = {}) {
  if (typeof idToken !== 'string' || !idToken.trim()) {
    const err = new Error('idToken is required');
    err.status = 400;
    throw err;
  }

  const clientId = getGoogleClientId();
  if (!clientId) {
    const err = new Error('GOOGLE_CLIENT_ID is not configured');
    err.status = 503;
    throw err;
  }

  const client = new OAuth2Client(clientId);
  let ticket;
  try {
    ticket = await client.verifyIdToken({
      idToken: idToken.trim(),
      audience: clientId,
    });
  } catch (_) {
    const err = new Error('Invalid Google ID token');
    err.status = 401;
    throw err;
  }

  const payload = ticket.getPayload();
  if (!payload?.email) {
    const err = new Error('Google token did not include an email');
    err.status = 401;
    throw err;
  }
  if (payload.email_verified === false) {
    const err = new Error('Google email is not verified');
    err.status = 401;
    throw err;
  }

  const email = String(payload.email).trim().toLowerCase();
  const fullName = payload.name || null;
  const picture = payload.picture || null;

  const existing = await pool.query(
    `select id, email, phone, username, phone_verified_at, email_verified_at, created_at
     from users where email = $1`,
    [email]
  );

  let user;
  // Welcome new accounts, and existing ones whose email was never verified
  // (they signed up with email but never got the welcome email).
  let welcome = false;
  if (existing.rows[0]) {
    welcome = !existing.rows[0].email_verified_at;
    const updated = await pool.query(
      `update users
       set email_verified_at = coalesce(email_verified_at, now())
       where id = $1
       returning id, email, phone, username, phone_verified_at, email_verified_at, created_at`,
      [existing.rows[0].id]
    );
    user = updated.rows[0];
  } else {
    const inserted = await pool.query(
      `insert into users (email, email_verified_at)
       values ($1, now())
       returning id, email, phone, username, phone_verified_at, email_verified_at, created_at`,
      [email]
    );
    user = inserted.rows[0];
    welcome = true;
  }

  const session = await issueSession(user, ctx);
  if (welcome) {
    await sendGoogleWelcome(email, payload.given_name || fullName);
  }
  return {
    user: {
      ...publicUser(user),
      // optional profile hints from Google (not persisted yet)
      name: fullName,
      picture,
    },
    ...session,
  };
}

module.exports = { loginWithGoogleIdToken, getGoogleClientId };
