const { OAuth2Client } = require('google-auth-library');
const jwt = require('jsonwebtoken');
const { pool } = require('../db/pool');
const { publicUser } = require('./emailAuth');

const JWT_EXPIRES = '7d';

function getGoogleClientId() {
  return (process.env.GOOGLE_CLIENT_ID || '').trim();
}

function signToken(user) {
  const secret = process.env.JWT_SECRET;
  if (!secret) {
    const err = new Error('JWT_SECRET is not configured');
    err.status = 500;
    throw err;
  }
  return jwt.sign(
    { sub: user.id, email: user.email || null, phone: user.phone || null, typ: 'access' },
    secret,
    { expiresIn: JWT_EXPIRES }
  );
}

async function loginWithGoogleIdToken(idToken) {
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
    `select id, email, phone, phone_verified_at, email_verified_at, created_at
     from users where email = $1`,
    [email]
  );

  let user;
  if (existing.rows[0]) {
    const updated = await pool.query(
      `update users
       set email_verified_at = coalesce(email_verified_at, now())
       where id = $1
       returning id, email, phone, phone_verified_at, email_verified_at, created_at`,
      [existing.rows[0].id]
    );
    user = updated.rows[0];
  } else {
    const inserted = await pool.query(
      `insert into users (email, email_verified_at)
       values ($1, now())
       returning id, email, phone, phone_verified_at, email_verified_at, created_at`,
      [email]
    );
    user = inserted.rows[0];
  }

  const token = signToken(user);
  return {
    user: {
      ...publicUser(user),
      // optional profile hints from Google (not persisted yet)
      name: fullName,
      picture,
    },
    token,
  };
}

module.exports = { loginWithGoogleIdToken, getGoogleClientId };
