const express = require('express');
const rateLimit = require('express-rate-limit');
const jwt = require('jsonwebtoken');
const { pool } = require('../db/pool');
const { requireAuth } = require('../middleware/auth');
const v = require('../validation');
const { asyncRoute } = require('./http');

const router = express.Router();
const route = asyncRoute('Support request failed', 'support');

const submitLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many support submissions. Try again later.' },
});

// Best-effort user extraction if bearer token is supplied
function tryExtractUserId(req) {
  try {
    const authHeader = req.headers.authorization || '';
    const match = authHeader.match(/^Bearer\s+(.+)$/i);
    if (!match || !process.env.JWT_SECRET) return null;
    const payload = jwt.verify(match[1], process.env.JWT_SECRET);
    return payload?.sub || null;
  } catch (_) {
    return null;
  }
}

// POST /support - submit support ticket / contact message
router.post('/', submitLimiter, route(async (req, res) => {
  const b = req.body || {};
  const name = v.text(b.name, 'name', { min: 2, max: 100 });
  const email = v.text(b.email, 'email', { min: 5, max: 120, optional: !b.phone });
  const phone = v.text(b.phone, 'phone', { min: 7, max: 25, optional: !b.email });
  const subject = v.text(b.subject, 'subject', { min: 3, max: 200 });
  const message = v.text(b.message, 'message', { min: 5, max: 3000 });
  const category = v.text(b.category, 'category', { min: 2, max: 50, optional: true }) || 'general';

  const userId = tryExtractUserId(req);

  const query = `
    insert into public.support_inquiries (name, email, phone, subject, message, category, user_id)
    values ($1, $2, $3, $4, $5, $6, $7)
    returning id, name, email, phone, subject, category, status, created_at
  `;
  const { rows } = await pool.query(query, [name, email, phone, subject, message, category, userId]);

  return res.status(201).json({
    ok: true,
    message: 'Support inquiry received. Our team will contact you shortly.',
    inquiry: rows[0],
  });
}));

// GET /support/my - list inquiries submitted by current user
router.get('/my', requireAuth, route(async (req, res) => {
  const query = `
    select id, name, email, phone, subject, message, category, status, created_at, updated_at
    from public.support_inquiries
    where user_id = $1
    order by created_at desc
    limit 50
  `;
  const { rows } = await pool.query(query, [req.user.id]);
  return res.json({ inquiries: rows });
}));

module.exports = router;
