const bcrypt = require('bcryptjs');
const crypto = require('crypto');
const { pool } = require('../db/pool');
const { getEmailConfig, sendEmail, verificationEmail, welcomeEmail, esc, layout } = require('./sendchampEmail');
const { issueSession } = require('./sessions');
const {
  normalizeUsername,
  isReserved,
  invalidUsernameError,
  takenUsernameError,
  uniqueViolationKind,
  isUsernameTaken,
} = require('./usernames');

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/i;
const E164 = /^\+[1-9][0-9]{7,14}$/;
const BCRYPT_COST = 12;
const VERIFY_TTL_MS = 24 * 60 * 60 * 1000;
const RESEND_COOLDOWN_MS = 60 * 1000;
const VERIFY_MESSAGE = 'Check your email to verify your account';
const VERIFY_MESSAGE_NOT_SENT =
  "Account created, but we couldn't send the verification email right now. Please try resending it in a few minutes.";

function normalizeEmail(email) {
  if (typeof email !== 'string') return null;
  const v = email.trim().toLowerCase();
  if (!EMAIL_RE.test(v) || v.length > 254) return null;
  return v;
}

function normalizePhoneOptional(phone) {
  if (phone === undefined || phone === null || phone === '') return null;
  if (typeof phone !== 'string') return undefined;
  const trimmed = phone.trim().replace(/[\s()-]/g, '');
  if (!E164.test(trimmed)) return undefined;
  return trimmed;
}

function publicUser(row) {
  return {
    id: row.id,
    email: row.email,
    phone: row.phone,
    username: row.username || null,
    role: row.role || 'consumer',
  };
}

function hashToken(token) {
  return crypto.createHash('sha256').update(String(token)).digest('hex');
}

// Create a fresh verification token (invalidating older ones) and email the link.
// Returns true when the email was handed to the provider; never throws for mail problems.
async function issueVerificationEmail(user) {
  const cfg = getEmailConfig();
  const token = crypto.randomBytes(32).toString('hex');
  await pool.query(
    `update email_verification_tokens set used_at = now() where user_id = $1 and used_at is null`,
    [user.id]
  );
  await pool.query(
    `insert into email_verification_tokens (user_id, token_hash, expires_at) values ($1, $2, $3)`,
    [user.id, hashToken(token), new Date(Date.now() + VERIFY_TTL_MS).toISOString()]
  );
  const link = `${cfg.apiBaseUrl}/auth/verify-email?token=${token}`;
  const mail = verificationEmail({ email: user.email, link });
  if (!cfg.configured) {
    console.warn('[email] SENDCHAMP_EMAIL_FROM (or SENDCHAMP_PUBLIC_KEY) is not set: verification email NOT sent. User must use resend after it is configured.');
    return false;
  }
  try {
    await sendEmail({ to: user.email, ...mail });
    return true;
  } catch (e) {
    console.error('[email] verification email failed:', e && e.code);
    return false;
  }
}

async function signup({ email, password, phone, username }) {
  const normalizedEmail = normalizeEmail(email);
  if (!normalizedEmail) {
    const err = new Error('Valid email is required');
    err.status = 400;
    throw err;
  }
  if (typeof password !== 'string' || password.length < 8) {
    const err = new Error('Password must be at least 8 characters');
    err.status = 400;
    throw err;
  }
  if (password.length > 128) {
    const err = new Error('Password is too long');
    err.status = 400;
    throw err;
  }

  const normalizedPhone = normalizePhoneOptional(phone);
  if (normalizedPhone === undefined) {
    const err = new Error('phone must be E.164 if provided, e.g. +2348012345678');
    err.status = 400;
    throw err;
  }

  const normalizedUsername = normalizeUsername(username);
  if (normalizedUsername === undefined) {
    throw invalidUsernameError();
  }
  if (normalizedUsername && isReserved(normalizedUsername)) {
    throw invalidUsernameError('This username is not available');
  }

  const passwordHash = await bcrypt.hash(password, BCRYPT_COST);

  let user;
  try {
    const { rows } = await pool.query(
      `insert into users (email, phone, password_hash, username)
       values ($1, $2, $3, $4)
       returning id, email, phone, username, created_at`,
      [normalizedEmail, normalizedPhone, passwordHash, normalizedUsername]
    );
    user = rows[0];
  } catch (e) {
    if (e.code === '23505') {
      if (uniqueViolationKind(e) === 'username') throw takenUsernameError();
      const err = new Error('Email or phone already registered');
      err.status = 409;
      throw err;
    }
    throw e;
  }

  // No login token until the email address is verified.
  let emailSent = false;
  try {
    emailSent = await issueVerificationEmail(user);
  } catch (e) {
    console.error('[email] could not create verification token:', e && e.code, e && e.message);
  }
  return {
    verificationRequired: true,
    emailSent,
    message: emailSent ? VERIFY_MESSAGE : VERIFY_MESSAGE_NOT_SENT,
    user: publicUser(user),
  };
}

async function login({ email, username, identifier, password }, ctx = {}) {
  const rawId = [identifier, email, username].find((v) => typeof v === 'string' && v.trim());
  if (!rawId) {
    const err = new Error('Email or username is required');
    err.status = 400;
    throw err;
  }
  if (typeof password !== 'string' || password.length < 1) {
    const err = new Error('Password is required');
    err.status = 400;
    throw err;
  }

  const normalizedEmail = normalizeEmail(rawId);
  const normalizedUsername = normalizedEmail ? null : normalizeUsername(rawId, { required: true });
  if (!normalizedEmail && !normalizedUsername) {
    const err = new Error('Enter a valid email or username');
    err.status = 400;
    throw err;
  }

  const { rows } = await pool.query(
    normalizedEmail
      ? `select id, email, phone, username, password_hash, email_verified_at, role from users where email = $1`
      : `select id, email, phone, username, password_hash, email_verified_at, role from users where username = $1`,
    [normalizedEmail || normalizedUsername]
  );
  const row = rows[0];
  if (!row || !row.password_hash) {
    const err = new Error('Invalid email, username or password');
    err.status = 401;
    throw err;
  }

  const ok = await bcrypt.compare(password, row.password_hash);
  if (!ok) {
    const err = new Error('Invalid email, username or password');
    err.status = 401;
    throw err;
  }

  if (!row.email_verified_at) {
    const err = new Error('Please verify your email first');
    err.status = 403;
    err.code = 'EMAIL_NOT_VERIFIED';
    throw err;
  }

  const session = await issueSession(row, ctx);
  return { user: publicUser(row), ...session };
}

// Consume a verification token. Returns { ok, user? }; ok=false for invalid/expired/used.
async function verifyEmailToken(token) {
  if (typeof token !== 'string' || !/^[0-9a-f]{64}$/i.test(token)) return { ok: false };
  const { rows } = await pool.query(
    `with t as (
       update email_verification_tokens
          set used_at = now()
        where token_hash = $1 and used_at is null and expires_at > now()
        returning user_id
     )
     update users u
        set email_verified_at = coalesce(u.email_verified_at, now())
       from t
      where u.id = t.user_id
      returning u.id, u.email, u.full_name`,
    [hashToken(token.toLowerCase())]
  );
  const user = rows[0];
  if (!user) return { ok: false };
  // Best-effort welcome email: never fails verification.
  try {
    if (user.email && getEmailConfig().configured) {
      await sendEmail({ to: user.email, ...welcomeEmail({ email: user.email, name: user.full_name }) });
    }
  } catch (e) {
    console.error('[email] welcome email failed:', e && e.code);
  }
  return { ok: true, user: { id: user.id, email: user.email } };
}

// Generic outcome regardless of whether the account exists (no enumeration).
async function resendVerification(emailRaw) {
  const email = normalizeEmail(emailRaw);
  if (!email) {
    const err = new Error('Valid email is required');
    err.status = 400;
    throw err;
  }
  try {
    const { rows } = await pool.query(
      `select u.id, u.email, u.email_verified_at, u.password_hash,
              (select max(created_at) from email_verification_tokens t where t.user_id = u.id) as last_sent
         from users u where u.email = $1`,
      [email]
    );
    const u = rows[0];
    const recent = u && u.last_sent && Date.now() - new Date(u.last_sent).getTime() < RESEND_COOLDOWN_MS;
    if (u && u.password_hash && !u.email_verified_at && !recent) {
      await issueVerificationEmail(u);
    }
  } catch (e) {
    console.error('[email] resend failed:', e && e.code, e && e.message);
  }
  return { ok: true, message: 'If an account exists for that email and still needs verification, a new link has been sent.' };
}


async function checkUsernameAvailable(raw) {
  const username = normalizeUsername(raw, { required: true });
  if (!username) throw invalidUsernameError();
  if (isReserved(username)) return { available: false, username };
  const taken = await isUsernameTaken(pool, username);
  return { available: !taken, username };
}

async function setUsername(userId, raw) {
  const username = normalizeUsername(raw, { required: true });
  if (!username) throw invalidUsernameError();
  if (isReserved(username)) throw invalidUsernameError('This username is not available');
  try {
    const { rows } = await pool.query(
      `update users set username = $1 where id = $2
       returning id, email, phone, username, role, phone_verified_at, email_verified_at, created_at`,
      [username, userId]
    );
    if (!rows[0]) {
      const err = new Error('User not found');
      err.status = 401;
      throw err;
    }
    return { user: publicUser(rows[0]) };
  } catch (e) {
    if (e.status) throw e;
    if (uniqueViolationKind(e) === 'username') throw takenUsernameError();
    throw e;
  }
}

async function requestPasswordReset(rawEmail) {
  const email = normalizeEmail(rawEmail);
  if (!email) {
    const err = new Error('Valid email is required');
    err.status = 400;
    throw err;
  }

  try {
    const { rows } = await pool.query(
      'select id, email, password_hash from public.users where email = $1',
      [email]
    );
    const u = rows[0];
    if (u) {
      const token = crypto.randomBytes(32).toString('hex');
      const tokenHash = hashToken(token);
      await pool.query(
        `insert into public.password_reset_tokens (user_id, token_hash, expires_at)
         values ($1, $2, now() + interval '1 hour')`,
        [u.id, tokenHash]
      );
      const { apiBaseUrl } = getEmailConfig();
      const resetUrl = `${apiBaseUrl.replace(/\/$/, '')}/auth/reset-password?token=${encodeURIComponent(token)}`;
      const html = layout(
        'Reset your XP GAS password',
        `<p style="font-size:15px;line-height:24px;color:#1b2430">We received a request to reset the password for your XP GAS account (${esc(u.email)}).</p>
         <p style="margin:24px 0"><a href="${esc(resetUrl)}" style="display:inline-block;background:#0053BA;color:#ffffff;font-weight:700;padding:12px 24px;border-radius:8px;text-decoration:none">Reset Password</a></p>
         <p style="font-size:13px;color:#64748b">This link expires in 1 hour. If you did not request a password reset, you can safely ignore this email.</p>`
      );
      await sendEmail({
        to: u.email,
        subject: 'Reset your XP GAS password',
        html,
        text: `Reset your XP GAS password using this link (valid for 1 hour): ${resetUrl}`,
      }).catch((e) => console.error('[email] password reset send failed:', e && e.message));
    }
  } catch (e) {
    console.error('[auth] requestPasswordReset failed:', e && e.code, e && e.message);
  }

  return {
    ok: true,
    message: 'If an account exists for that email, a password reset link has been sent.',
  };
}

async function resetPassword({ token, newPassword }) {
  const raw = typeof token === 'string' ? token.trim() : '';
  if (!/^[a-f0-9]{64}$/i.test(raw)) {
    const err = new Error('Invalid or expired password reset link');
    err.status = 400;
    throw err;
  }
  if (typeof newPassword !== 'string' || newPassword.length < 8 || newPassword.length > 72) {
    const err = new Error('Password must be 8-72 characters');
    err.status = 400;
    throw err;
  }

  const tokenHash = hashToken(raw);
  const hash = await bcrypt.hash(newPassword, BCRYPT_COST);

  const client = await pool.connect();
  try {
    await client.query('begin');
    const { rows } = await client.query(
      `update public.password_reset_tokens
          set used_at = now()
        where token_hash = $1 and used_at is null and expires_at > now()
        returning user_id`,
      [tokenHash]
    );
    if (!rows[0]) {
      await client.query('rollback');
      const err = new Error('Invalid or expired password reset link');
      err.status = 400;
      throw err;
    }
    const userId = rows[0].user_id;
    await client.query(
      `update public.users
          set password_hash = $1,
              email_verified_at = coalesce(email_verified_at, now())
        where id = $2`,
      [hash, userId]
    );
    await client.query(
      'update public.auth_sessions set revoked_at = now() where user_id = $1 and revoked_at is null',
      [userId]
    ).catch(() => {});
    await client.query('commit');
  } catch (err) {
    await client.query('rollback').catch(() => {});
    throw err;
  } finally {
    client.release();
  }

  return { ok: true, message: 'Password updated successfully. You can now sign in.' };
}

module.exports = { signup, login, publicUser, verifyEmailToken, resendVerification, hashToken, checkUsernameAvailable, setUsername, requestPasswordReset, resetPassword };
