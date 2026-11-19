// Login sessions: short-lived JWT access tokens + rotating opaque refresh tokens.
//
// * Access token: JWT (HS256, JWT_SECRET), default 1h, carries sid = session family.
// * Refresh token: 32 random bytes (base64url). Only sha256(token) is stored in
//   public.auth_sessions (sql/005_auth_sessions.sql). Rotated on every use.
// * Reusing a rotated refresh token (outside a short grace window) revokes the
//   whole family -> every device token from that login stops working.
// * If the auth_sessions table is missing (migration not applied yet) we fall
//   back to the previous behaviour: a single 7-day access token, no refresh.
const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const { pool } = require('../db/pool');

const LEGACY_ACCESS_TTL = '7d';
const ROTATION_GRACE_MS = 30 * 1000;
const UNDEFINED_TABLE = '42P01';

function accessTtl() {
  return (process.env.JWT_ACCESS_TTL || '1h').trim();
}

function refreshTtlDays() {
  const n = Number(process.env.REFRESH_TOKEN_TTL_DAYS);
  return Number.isFinite(n) && n > 0 && n <= 365 ? n : 60;
}

function jwtSecret() {
  const secret = process.env.JWT_SECRET;
  if (!secret) {
    const err = new Error('JWT_SECRET is not configured');
    err.status = 500;
    throw err;
  }
  return secret;
}

function signAccessToken(user, { sid, expiresIn } = {}) {
  const payload = { sub: user.id, email: user.email || null, phone: user.phone || null, typ: 'access' };
  if (sid) payload.sid = sid;
  return jwt.sign(payload, jwtSecret(), { expiresIn: expiresIn || accessTtl() });
}

function newRefreshToken() {
  return crypto.randomBytes(32).toString('base64url');
}

function hashRefreshToken(token) {
  return crypto.createHash('sha256').update(String(token)).digest('hex');
}

function clean(value, max) {
  if (typeof value !== 'string') return null;
  const v = value.replace(/[\u0000-\u001f\u007f]/g, '').trim();
  return v ? v.slice(0, max) : null;
}

function ttlSeconds(token) {
  const decoded = jwt.decode(token);
  return decoded && decoded.exp && decoded.iat ? decoded.exp - decoded.iat : undefined;
}

function unauthorized(message = 'Session expired. Please sign in again.', code = 'INVALID_REFRESH_TOKEN') {
  const err = new Error(message);
  err.status = 401;
  err.code = code;
  return err;
}

function sessionResponse(user, accessToken, refreshToken) {
  const body = { token: accessToken, expiresIn: ttlSeconds(accessToken) };
  if (refreshToken) body.refreshToken = refreshToken;
  if (user) body.user = { id: user.id, email: user.email ?? null, phone: user.phone ?? null };
  return body;
}

async function insertSession(db, { userId, familyId, deviceLabel, userAgent }) {
  const refreshToken = newRefreshToken();
  const { rows } = await db.query(
    `insert into public.auth_sessions (user_id, family_id, token_hash, device_label, user_agent, expires_at)
     values ($1, $2, $3, $4, $5, now() + make_interval(days => $6))
     returning id, family_id`,
    [userId, familyId, hashRefreshToken(refreshToken), deviceLabel, userAgent, refreshTtlDays()]
  );
  return { refreshToken, id: rows[0].id, familyId: rows[0].family_id };
}

/**
 * Issue tokens after a successful login. Returns { token, refreshToken?, expiresIn }.
 * ctx: { deviceLabel, userAgent } (both optional, from the request).
 */
async function issueSession(user, ctx = {}) {
  const deviceLabel = clean(ctx.deviceLabel, 100);
  const userAgent = clean(ctx.userAgent, 300);
  try {
    // Opportunistic cleanup of this user's stale rows (cheap, indexed by user).
    await pool.query(
      `delete from public.auth_sessions
        where user_id = $1 and (expires_at < now() - interval '30 days' or revoked_at < now() - interval '30 days')`,
      [user.id]
    );
    const s = await insertSession(pool, {
      userId: user.id,
      familyId: crypto.randomUUID(),
      deviceLabel,
      userAgent,
    });
    const token = signAccessToken(user, { sid: s.familyId });
    return { token, refreshToken: s.refreshToken, expiresIn: ttlSeconds(token) };
  } catch (err) {
    if (err && err.code === UNDEFINED_TABLE) {
      console.warn('[sessions] auth_sessions table missing; issuing legacy 7d token. Apply sql/005_auth_sessions.sql.');
      const token = signAccessToken(user, { expiresIn: LEGACY_ACCESS_TTL });
      return { token, expiresIn: ttlSeconds(token) };
    }
    throw err;
  }
}

/** Rotate a refresh token. Returns { token, refreshToken, expiresIn, user }. */
async function refreshSession(rawToken, ctx = {}) {
  if (typeof rawToken !== 'string' || rawToken.length < 20 || rawToken.length > 200) throw unauthorized();
  const client = await pool.connect();
  try {
    await client.query('begin');
    const { rows } = await client.query(
      `select s.id, s.user_id, s.family_id, s.device_label, s.expires_at, s.revoked_at, s.revoked_reason,
              u.email, u.phone
         from public.auth_sessions s
         join public.users u on u.id = s.user_id
        where s.token_hash = $1
        for update of s`,
      [hashRefreshToken(rawToken)]
    );
    const row = rows[0];
    if (!row) {
      await client.query('rollback');
      throw unauthorized();
    }

    if (row.revoked_at) {
      const recentlyRotated =
        row.revoked_reason === 'rotated' && Date.now() - new Date(row.revoked_at).getTime() < ROTATION_GRACE_MS;
      if (recentlyRotated) {
        // Two refreshes raced (e.g. two browser tabs). Not theft; ask the client to retry with its newest token.
        await client.query('rollback');
        const err = new Error('Session was just refreshed. Retry with the latest token.');
        err.status = 409;
        err.code = 'REFRESH_RACE';
        throw err;
      }
      if (row.revoked_reason === 'rotated') {
        await client.query(
          `update public.auth_sessions set revoked_at = now(), revoked_reason = 'reuse_detected'
            where family_id = $1 and revoked_at is null`,
          [row.family_id]
        );
        await client.query('commit');
        console.warn('[sessions] refresh token reuse detected; family revoked', row.family_id);
        throw unauthorized();
      }
      await client.query('rollback');
      throw unauthorized();
    }

    if (new Date(row.expires_at).getTime() <= Date.now()) {
      await client.query('rollback');
      throw unauthorized();
    }

    const next = await insertSession(client, {
      userId: row.user_id,
      familyId: row.family_id,
      deviceLabel: clean(ctx.deviceLabel, 100) || row.device_label,
      userAgent: clean(ctx.userAgent, 300),
    });
    await client.query(
      `update public.auth_sessions
          set revoked_at = now(), revoked_reason = 'rotated', replaced_by = $2, last_used_at = now()
        where id = $1`,
      [row.id, next.id]
    );
    await client.query('commit');

    const user = { id: row.user_id, email: row.email, phone: row.phone };
    const token = signAccessToken(user, { sid: row.family_id });
    return sessionResponse(user, token, next.refreshToken);
  } catch (err) {
    if (!err.status) {
      try { await client.query('rollback'); } catch (_) {}
    }
    throw err;
  } finally {
    client.release();
  }
}

/** Revoke the login (whole family) a refresh token belongs to. Idempotent; never reveals validity. */
async function revokeSession(rawToken) {
  if (typeof rawToken !== 'string' || rawToken.length < 20 || rawToken.length > 200) return { ok: true };
  try {
    await pool.query(
      `update public.auth_sessions set revoked_at = now(), revoked_reason = 'logout'
        where revoked_at is null
          and family_id = (select family_id from public.auth_sessions where token_hash = $1)`,
      [hashRefreshToken(rawToken)]
    );
  } catch (err) {
    if (!(err && err.code === UNDEFINED_TABLE)) throw err;
  }
  return { ok: true };
}

/** Revoke a login by its family id (used with the access token's sid). */
async function revokeFamily(familyId, reason = 'logout') {
  if (!familyId) return { ok: true };
  await pool.query(
    `update public.auth_sessions set revoked_at = now(), revoked_reason = $2
      where family_id = $1 and revoked_at is null`,
    [familyId, reason]
  );
  return { ok: true };
}

/** Revoke every session of a user ("log out everywhere"). */
async function revokeAllForUser(userId) {
  await pool.query(
    `update public.auth_sessions set revoked_at = now(), revoked_reason = 'logout_all'
      where user_id = $1 and revoked_at is null`,
    [userId]
  );
  return { ok: true };
}

module.exports = {
  issueSession,
  refreshSession,
  revokeSession,
  revokeFamily,
  revokeAllForUser,
  signAccessToken,
  hashRefreshToken,
  accessTtl,
  refreshTtlDays,
};
