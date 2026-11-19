const jwt = require('jsonwebtoken');
const { pool } = require('../db/pool');

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function requireAuth(req, res, next) {
  try {
    const header = req.headers.authorization || '';
    const match = header.match(/^Bearer\s+(.+)$/i);
    if (!match) {
      return res.status(401).json({ error: 'Missing or invalid Authorization header. Use Bearer <token>.' });
    }

    const secret = process.env.JWT_SECRET;
    if (!secret) {
      return res.status(500).json({ error: 'JWT_SECRET is not configured' });
    }

    let payload;
    try {
      payload = jwt.verify(match[1], secret);
    } catch (_) {
      return res.status(401).json({ error: 'Invalid or expired token' });
    }

    if (!payload?.sub || (payload.typ && payload.typ !== 'access')) {
      return res.status(401).json({ error: 'Invalid token payload' });
    }

    // Tokens with a session id (sid) are only valid while that login is not revoked
    // (logout, refresh-token reuse). Legacy tokens without sid skip this check.
    const sid = typeof payload.sid === 'string' && UUID_RE.test(payload.sid) ? payload.sid : null;
    // The session subquery is only added when sid is present, so legacy tokens keep
    // working even before sql/005_auth_sessions.sql is applied.
    const sessionCheck = sid
      ? `exists (select 1 from public.auth_sessions s
                  where s.family_id = $2::uuid and s.revoked_at is null and s.expires_at > now())`
      : 'true';
    const { rows } = await pool.query(
      `select u.id, u.email, u.phone, u.role, u.phone_verified_at, u.email_verified_at, u.created_at,
              ${sessionCheck} as session_active
         from users u where u.id = $1`,
      sid ? [payload.sub, sid] : [payload.sub]
    );
    const row = rows[0];
    if (!row) {
      return res.status(401).json({ error: 'User not found for this token' });
    }
    if (!row.session_active) {
      return res.status(401).json({ error: 'Session has been signed out', code: 'SESSION_REVOKED' });
    }
    const { session_active: _active, ...user } = row;

    req.user = user;
    req.auth = payload;
    return next();
  } catch (err) {
    console.error('[auth middleware]', err);
    return res.status(500).json({ error: 'Auth check failed' });
  }
}

function requireAdmin(req, res, next) {
  if (req.user?.role !== 'admin') {
    return res.status(403).json({ error: 'Admin access required' });
  }
  return next();
}

module.exports = { requireAuth, requireAdmin };
