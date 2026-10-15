const jwt = require('jsonwebtoken');
const { pool } = require('../db/pool');

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

    if (!payload?.sub) {
      return res.status(401).json({ error: 'Invalid token payload' });
    }

    const { rows } = await pool.query(
      `select id, email, phone, role, phone_verified_at, email_verified_at, created_at
       from users where id = $1`,
      [payload.sub]
    );
    const user = rows[0];
    if (!user) {
      return res.status(401).json({ error: 'User not found for this token' });
    }

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
