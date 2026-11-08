const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { pool } = require('../db/pool');

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/i;
const E164 = /^\+[1-9][0-9]{7,14}$/;
const BCRYPT_COST = 12;
const JWT_EXPIRES = '7d';

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

function publicUser(row) {
  return {
    id: row.id,
    email: row.email,
    phone: row.phone,
  };
}

async function signup({ email, password, phone }) {
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

  const passwordHash = await bcrypt.hash(password, BCRYPT_COST);

  try {
    const { rows } = await pool.query(
      `insert into users (email, phone, password_hash)
       values ($1, $2, $3)
       returning id, email, phone, created_at`,
      [normalizedEmail, normalizedPhone, passwordHash]
    );
    const user = rows[0];
    const token = signToken(user);
    return { user: publicUser(user), token };
  } catch (e) {
    if (e.code === '23505') {
      const err = new Error('Email or phone already registered');
      err.status = 409;
      throw err;
    }
    throw e;
  }
}

async function login({ email, password }) {
  const normalizedEmail = normalizeEmail(email);
  if (!normalizedEmail) {
    const err = new Error('Valid email is required');
    err.status = 400;
    throw err;
  }
  if (typeof password !== 'string' || password.length < 1) {
    const err = new Error('Password is required');
    err.status = 400;
    throw err;
  }

  const { rows } = await pool.query(
    `select id, email, phone, password_hash from users where email = $1`,
    [normalizedEmail]
  );
  const row = rows[0];
  if (!row || !row.password_hash) {
    const err = new Error('Invalid email or password');
    err.status = 401;
    throw err;
  }

  const ok = await bcrypt.compare(password, row.password_hash);
  if (!ok) {
    const err = new Error('Invalid email or password');
    err.status = 401;
    throw err;
  }

  const token = signToken(row);
  return { user: publicUser(row), token };
}

module.exports = { signup, login, publicUser };
