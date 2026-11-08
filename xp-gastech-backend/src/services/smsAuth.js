const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { pool } = require('../db/pool');
const { sendSms, getTwilioConfig } = require('./twilio');

const CODE_TTL_MS = 10 * 60 * 1000;
const MAX_ATTEMPTS = 5;
const E164 = /^\+[1-9][0-9]{7,14}$/;

function normalizePhone(phone) {
  if (typeof phone !== 'string') return null;
  const trimmed = phone.trim().replace(/[\s()-]/g, '');
  if (!E164.test(trimmed)) return null;
  return trimmed;
}

function generateCode() {
  return String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
}

async function upsertUserByPhone(client, phone) {
  const existing = await client.query('select id, email, phone, created_at from users where phone = $1', [phone]);
  if (existing.rows[0]) return existing.rows[0];
  const inserted = await client.query(
    `insert into users (phone) values ($1)
     returning id, email, phone, created_at`,
    [phone]
  );
  return inserted.rows[0];
}

async function sendSmsCode(phoneRaw) {
  const phone = normalizePhone(phoneRaw);
  if (!phone) {
    const err = new Error('phone must be E.164, e.g. +2348012345678');
    err.status = 400;
    throw err;
  }

  const code = generateCode();
  const codeHash = await bcrypt.hash(code, 10);
  const expiresAt = new Date(Date.now() + CODE_TTL_MS);

  const client = await pool.connect();
  try {
    await client.query('begin');
    // Invalidate unused prior codes for this phone
    await client.query(
      `update sms_verification_codes
       set consumed_at = now()
       where phone = $1 and consumed_at is null`,
      [phone]
    );
    await client.query(
      `insert into sms_verification_codes (phone, code_hash, expires_at)
       values ($1, $2, $3)`,
      [phone, codeHash, expiresAt.toISOString()]
    );
    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  } finally {
    client.release();
  }

  const twilio = getTwilioConfig();
  if (twilio.configured) {
    await sendSms(phone, `Your XP GasTech verification code is ${code}. It expires in 10 minutes.`);
    return { ok: true, phone, twilioConfigured: true, expiresInSeconds: 600 };
  }

  // Dev fallback when Twilio env is empty — never log the code in production logs beyond this flag
  const payload = {
    ok: true,
    phone,
    twilioConfigured: false,
    expiresInSeconds: 600,
    message: 'Twilio credentials missing. Set TWILIO_* in .env to send real SMS.',
  };
  if (process.env.NODE_ENV !== 'production') {
    payload.devCode = code;
  }
  return payload;
}

async function verifySmsCode(phoneRaw, codeRaw) {
  const phone = normalizePhone(phoneRaw);
  const code = typeof codeRaw === 'string' ? codeRaw.trim() : '';
  if (!phone) {
    const err = new Error('phone must be E.164, e.g. +2348012345678');
    err.status = 400;
    throw err;
  }
  if (!/^\d{6}$/.test(code)) {
    const err = new Error('code must be a 6-digit string');
    err.status = 400;
    throw err;
  }

  const secret = process.env.JWT_SECRET;
  if (!secret) {
    const err = new Error('JWT_SECRET is not configured');
    err.status = 500;
    throw err;
  }

  const client = await pool.connect();
  try {
    await client.query('begin');
    const { rows } = await client.query(
      `select id, code_hash, expires_at, attempt_count
       from sms_verification_codes
       where phone = $1 and consumed_at is null
       order by created_at desc
       limit 1
       for update`,
      [phone]
    );
    const row = rows[0];
    if (!row) {
      const err = new Error('No active code for this phone. Request a new one.');
      err.status = 400;
      throw err;
    }
    if (new Date(row.expires_at).getTime() < Date.now()) {
      await client.query(`update sms_verification_codes set consumed_at = now() where id = $1`, [row.id]);
      await client.query('commit');
      const err = new Error('Code expired. Request a new one.');
      err.status = 400;
      throw err;
    }
    if (row.attempt_count >= MAX_ATTEMPTS) {
      await client.query(`update sms_verification_codes set consumed_at = now() where id = $1`, [row.id]);
      await client.query('commit');
      const err = new Error('Too many attempts. Request a new code.');
      err.status = 429;
      throw err;
    }

    const match = await bcrypt.compare(code, row.code_hash);
    if (!match) {
      await client.query(
        `update sms_verification_codes set attempt_count = attempt_count + 1 where id = $1`,
        [row.id]
      );
      await client.query('commit');
      const err = new Error('Invalid code');
      err.status = 401;
      throw err;
    }

    await client.query(
      `update sms_verification_codes set consumed_at = now() where id = $1`,
      [row.id]
    );
    const user = await upsertUserByPhone(client, phone);
    await client.query(
      `update users set phone_verified_at = coalesce(phone_verified_at, now()) where id = $1`,
      [user.id]
    );
    await client.query('commit');

    const token = jwt.sign(
      { sub: user.id, phone: user.phone, typ: 'access' },
      secret,
      { expiresIn: '7d' }
    );

    return {
      ok: true,
      token,
      user: { id: user.id, email: user.email, phone: user.phone, created_at: user.created_at },
    };
  } catch (e) {
    try { await client.query('rollback'); } catch (_) {}
    throw e;
  } finally {
    client.release();
  }
}

module.exports = { sendSmsCode, verifySmsCode, normalizePhone };
