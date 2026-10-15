const express = require('express');
const rateLimit = require('express-rate-limit');
const { pool } = require('../db/pool');
const { requireAuth } = require('../middleware/auth');
const v = require('../validation');
const { asyncRoute } = require('./http');

const router = express.Router();
const route = asyncRoute('Business request failed', 'businesses');
router.use(requireAuth);

const writeLimiter = rateLimit({
  windowMs: 60 * 1000, max: 120, standardHeaders: true, legacyHeaders: false,
  message: { error: 'Too many requests. Try again later.' },
});

const BIZ_COLUMNS = `id, name, state, city_lga, address_line,
  extensions.st_y(location::extensions.geometry) as latitude,
  extensions.st_x(location::extensions.geometry) as longitude, created_at, updated_at`;
const toBusiness = (r) => ({
  id: r.id, name: r.name, state: r.state, cityLga: r.city_lga, address: r.address_line,
  latitude: r.latitude, longitude: r.longitude, createdAt: r.created_at, updatedAt: r.updated_at,
});

async function myBusinessId(userId) {
  const { rows } = await pool.query('select id from public.businesses where app_user_id = $1', [userId]);
  return rows[0]?.id || null;
}

router.get('/me', route(async (req, res) => {
  const { rows } = await pool.query(`select ${BIZ_COLUMNS} from public.businesses where app_user_id = $1`, [req.user.id]);
  if (!rows[0]) return res.status(404).json({ error: 'No business profile yet' });
  return res.json({ business: toBusiness(rows[0]) });
}));

// Create or update the caller's business profile.
router.put('/me', writeLimiter, route(async (req, res) => {
  const b = req.body || {};
  const name = v.text(b.name, 'name', { min: 2, max: 120 });
  const address = v.text(b.address, 'address', { min: 3, max: 200, optional: true });
  const state = v.text(b.state, 'state', { min: 2, max: 80, optional: true });
  const city = v.text(b.cityLga, 'cityLga', { min: 2, max: 80, optional: true });
  const lat = v.num(b.latitude, 'latitude', { min: -90, max: 90, optional: true });
  const lng = v.num(b.longitude, 'longitude', { min: -180, max: 180, optional: true });
  if ((lat === null) !== (lng === null)) throw v.bad('latitude and longitude must be sent together');
  const { rows } = await pool.query(
    `insert into public.businesses (app_user_id, name, address_line, state, city_lga, location)
     values ($1, $2, $3, $4, $5, case when $6::float8 is null then null else
       extensions.st_setsrid(extensions.st_makepoint($7::float8, $6::float8), 4326)::extensions.geography end)
     on conflict (app_user_id) where app_user_id is not null do update set
       name = excluded.name, address_line = excluded.address_line, state = excluded.state,
       city_lga = excluded.city_lga, location = excluded.location
     returning ${BIZ_COLUMNS}`,
    [req.user.id, name, address, state, city, lat, lng]
  );
  return res.json({ business: toBusiness(rows[0]) });
}));

// Record one or more gas readings (single object or { readings: [...] }, max 200).
router.post('/me/gas-readings', writeLimiter, route(async (req, res) => {
  const businessId = await myBusinessId(req.user.id);
  if (!businessId) return res.status(404).json({ error: 'Create your business profile first (PUT /businesses/me)' });
  const list = Array.isArray(req.body?.readings) ? req.body.readings : [req.body || {}];
  if (!list.length || list.length > 200) throw v.bad('Send between 1 and 200 readings');
  const rows = list.map((r, i) => {
    const kg = v.num(r.kgLeft, `readings[${i}].kgLeft`, { min: 0, max: 1000, optional: true });
    const pct = v.num(r.percentLeft, `readings[${i}].percentLeft`, { min: 0, max: 100, optional: true });
    if (kg === null && pct === null) throw v.bad(`readings[${i}] needs kgLeft or percentLeft`);
    return [kg, pct,
      v.text(r.cylinderLabel, `readings[${i}].cylinderLabel`, { max: 80, optional: true }),
      v.isoDate(r.recordedAt, `readings[${i}].recordedAt`, { optional: true }) || new Date().toISOString()];
  });
  const { rowCount } = await pool.query(
    `insert into public.gas_readings (business_id, kg_left, percent_left, cylinder_label, recorded_at)
     select $1, x.kg, x.pct, x.label, x.at
     from unnest($2::numeric[], $3::numeric[], $4::text[], $5::timestamptz[]) as x(kg, pct, label, at)`,
    [businessId, rows.map((r) => r[0]), rows.map((r) => r[1]), rows.map((r) => r[2]), rows.map((r) => r[3])]
  );
  return res.status(201).json({ inserted: rowCount });
}));

// Latest reading + weekly usage for the last N weeks (default 8, max 52).
router.get('/me/gas', route(async (req, res) => {
  const weeks = req.query.weeks !== undefined ? Math.trunc(v.num(req.query.weeks, 'weeks', { min: 1, max: 52 })) : 8;
  const businessId = await myBusinessId(req.user.id);
  if (!businessId) return res.status(404).json({ error: 'Create your business profile first (PUT /businesses/me)' });
  const [latest, weekly] = await Promise.all([
    pool.query(
      `select kg_left, percent_left, cylinder_label, recorded_at from public.gas_readings
       where business_id = $1 order by recorded_at desc limit 1`, [businessId]),
    pool.query(
      `select week_start, kg_used, percent_used, readings from public.gas_weekly_usage
       where business_id = $1 and week_start >= (date_trunc('week', now()) - make_interval(weeks => $2 - 1))::date
       order by week_start desc`, [businessId, weeks]),
  ]);
  const l = latest.rows[0];
  return res.json({
    latest: l ? { kgLeft: l.kg_left === null ? null : Number(l.kg_left),
      percentLeft: l.percent_left === null ? null : Number(l.percent_left),
      cylinderLabel: l.cylinder_label, recordedAt: l.recorded_at } : null,
    weekly: weekly.rows.map((w) => ({ weekStart: w.week_start, kgUsed: Number(w.kg_used),
      percentUsed: Number(w.percent_used), readings: Number(w.readings) })),
  });
}));

module.exports = router;
