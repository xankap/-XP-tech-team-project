// Small, dependency-free validators. Each throws a 400-tagged Error on bad input.
function bad(message) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

function text(v, field, { min = 1, max = 200, optional = false } = {}) {
  if (v === undefined || v === null || v === '') {
    if (optional) return null;
    throw bad(`${field} is required`);
  }
  if (typeof v !== 'string') throw bad(`${field} must be a string`);
  const t = v.trim().replace(/\s+/g, ' ');
  if (t.length < min || t.length > max) throw bad(`${field} must be ${min}-${max} characters`);
  if (/[\u0000-\u001f\u007f]/.test(t)) throw bad(`${field} contains invalid characters`);
  return t;
}

function num(v, field, { min, max, optional = false } = {}) {
  if (v === undefined || v === null || v === '') {
    if (optional) return null;
    throw bad(`${field} is required`);
  }
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isFinite(n) || n < min || n > max) throw bad(`${field} must be a number between ${min} and ${max}`);
  return n;
}

function phone(v, field = 'phone') {
  const t = text(v, field, { min: 8, max: 20 }).replace(/[\s()-]/g, '');
  if (!/^\+[1-9][0-9]{7,14}$/.test(t)) throw bad(`${field} must be in international format, e.g. +2348012345678`);
  return t;
}

function bool(v, field) {
  if (typeof v !== 'boolean') throw bad(`${field} must be true or false`);
  return v;
}

function uuid(v, field = 'id') {
  if (typeof v !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)) {
    throw bad(`${field} must be a valid id`);
  }
  return v.toLowerCase();
}

function isoDate(v, field, { optional = false } = {}) {
  if (v === undefined || v === null || v === '') {
    if (optional) return null;
    throw bad(`${field} is required`);
  }
  const d = new Date(v);
  if (typeof v !== 'string' || Number.isNaN(d.getTime())) throw bad(`${field} must be an ISO-8601 timestamp`);
  const now = Date.now();
  if (d.getTime() > now + 5 * 60 * 1000) throw bad(`${field} cannot be in the future`);
  if (d.getTime() < now - 366 * 24 * 3600 * 1000) throw bad(`${field} is too old`);
  return d.toISOString();
}

const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const HHMM = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;
// opening_hours: { mon: { open: "08:00", close: "20:00" } | null, ... }
function openingHours(v, { optional = true } = {}) {
  if (v === undefined || v === null) {
    if (optional) return null;
    throw bad('openingHours is required');
  }
  if (typeof v !== 'object' || Array.isArray(v)) throw bad('openingHours must be an object keyed by day (mon..sun)');
  const out = {};
  for (const [k, val] of Object.entries(v)) {
    if (!DAYS.includes(k)) throw bad(`openingHours: unknown day "${k}"`);
    if (val === null) { out[k] = null; continue; }
    if (!val || !HHMM.test(val.open) || !HHMM.test(val.close)) {
      throw bad(`openingHours.${k} needs open/close as HH:MM`);
    }
    out[k] = { open: val.open, close: val.close };
  }
  return out;
}

module.exports = { bad, text, num, phone, bool, uuid, isoDate, openingHours };
