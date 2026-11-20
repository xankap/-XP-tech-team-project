const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const { pool } = require('../db/pool');
const { sendSms, getSmsConfig } = require('./sendchamp');
const { createVerification, confirmVerification } = require('./sendchampVerify');
const { issueSession } = require('./sessions');
const { publicUser } = require('./emailAuth');

const CODE_TTL_MS = 10 * 60 * 1000;
const MAX_ATTEMPTS = 5;
const E164 = /^\+[1-9][0-9]{7,14}$/;
// Stored in sms_verification_codes.code_hash for Verification API rows so
// we can recover the Sendchamp reference (the actual OTP is never stored).
const REF_PREFIX = 'scvr:';

function normalizePhone(phone) {
  if (typeof phone !== 'string') return null;
  const trimmed = phone.trim().replace(/[\s()-]/g, '');
  if (!E164.test(trimmed)) return null;
  return trimmed;
}

const DEFAULT_OTP_TEMPLATE = 'Your XP GasTech verification code is {{code}}. It expires in 10 minutes.';

// Customizable via SMS_OTP_TEMPLATE (must contain {{code}}); used only by the legacy fallback.
function buildOtpMessage(code) {
  const custom = (process.env.SMS_OTP_TEMPLATE || '').trim();
  const template = custom.includes('{{code}}') ? custom : DEFAULT_OTP_TEMPLATE;
  return template.split('{{code}}').join(code);
}

function generateCode() {
  return String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
}

function useLegacyOtp() {
  return (process.env.SENDCHAMP_OTP_MODE || '').trim().toLowerCase() === 'legacy';
}

async function upsertUserByPhone(client, phone) {
  const existing = await client.query('select id, email, phone, username, created_at from users where phone = $1', [phone]);
  if (existing.rows[0]) return existing.rows[0];
  const inserted = await client.query(
    `insert into users (phone) values ($1)
     returning id, email, phone, username, created_at`,
    [phone]
  );
  return inserted.rows[0];
}

async function storeCodeRow(phone, codeHash, expiresAt) {
  const client = await pool.connect();
  try {
    await client.query('begin');
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
}

async function sendSmsCodeLegacy(phone) {
  const code = generateCode();
  const codeHash = await bcrypt.hash(code, 10);
  const expiresAt = new Date(Date.now() + CODE_TTL_MS);
  await storeCodeRow(phone, codeHash, expiresAt);

  if (getSmsConfig().configured) {
    await sendSms(phone, buildOtpMessage(code));
    return { ok: true, phone, smsConfigured: true, expiresInSeconds: 600 };
  }

  const payload = {
    ok: true,
    phone,
    smsConfigured: false,
    expiresInSeconds: 600,
    message: 'SMS credentials missing. Set SENDCHAMP_PUBLIC_KEY in .env to send real SMS.',
  };
  if (process.env.NODE_ENV !== 'production') {
    payload.devCode = code;
  }
  return payload;
}

async function sendSmsCode(phoneRaw) {
  const phone = normalizePhone(phoneRaw);
  if (!phone) {
    const err = new Error('phone must be E.164, e.g. +2348012345678');
    err.status = 400;
    throw err;
  }

  if (useLegacyOtp() || !getSmsConfig().configured) {
    return sendSmsCodeLegacy(phone);
  }

  const { reference } = await createVerification({ phone });
  const expiresAt = new Date(Date.now() + CODE_TTL_MS);
  await storeCodeRow(phone, REF_PREFIX + reference, expiresAt);
  console.log('[sms] verification sent', { reference });
  return { ok: true, phone, smsConfigured: true, expiresInSeconds: 600 };
}

async function verifySmsCode(phoneRaw, codeRaw, ctx = {}) {
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

  let user;
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

    const isProvider = String(row.code_hash || '').startsWith(REF_PREFIX);
    if (isProvider) {
      const reference = row.code_hash.slice(REF_PREFIX.length);
      try {
        await confirmVerification({ reference, code });
      } catch (e) {
        if (e.code === 'OTP_INVALID') {
          await client.query(
            `update sms_verification_codes set attempt_count = attempt_count + 1 where id = $1`,
            [row.id]
          );
          await client.query('commit');
          const err = new Error('Invalid code');
          err.status = 401;
          throw err;
        }
        if (e.code === 'OTP_EXPIRED') {
          await client.query(`update sms_verification_codes set consumed_at = now() where id = $1`, [row.id]);
          await client.query('commit');
          const err = new Error('Code expired. Request a new one.');
          err.status = 400;
          throw err;
        }
        throw e;
      }
    } else {
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
    }

    await client.query(
      `update sms_verification_codes set consumed_at = now() where id = $1`,
      [row.id]
    );
    user = await upsertUserByPhone(client, phone);
    await client.query(
      `update users set phone_verified_at = coalesce(phone_verified_at, now()) where id = $1`,
      [user.id]
    );
    await client.query('commit');
  } catch (e) {
    try { await client.query('rollback'); } catch (_) {}
    throw e;
  } finally {
    client.release();
  }

  // Issued after the OTP transaction so the pooled connection is free again.
  const session = await issueSession(user, ctx);
  return {
    ok: true,
    ...session,
    user: { ...publicUser(user), created_at: user.created_at },
  };
}

module.exports = { sendSmsCode, verifySmsCode, normalizePhone, buildOtpMessage, REF_PREFIX };
