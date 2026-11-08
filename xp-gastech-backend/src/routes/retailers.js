const express = require('express');
const rateLimit = require('express-rate-limit');
const { pool } = require('../db/pool');
const { requireAuth, requireAdmin } = require('../middleware/auth');
const v = require('../validation');
const { asyncRoute } = require('./http');

const router = express.Router();
const route = asyncRoute('Retailer request failed', 'retailers');

const limiter = (max, windowMs = 15 * 60 * 1000) => rateLimit({
  windowMs, max, standardHeaders: true, legacyHeaders: false,
  message: { error: 'Too many requests. Try again later.' },
});
const writeLimiter = limiter(30);
const nearbyLimiter = limiter(60, 60 * 1000);

const OWN_COLUMNS = `id, name, phone_e164 as phone, address_line as address, state, city_lga,
  latitude, longitude, is_available, opening_hours, status, status_reason, created_at, updated_at`;

function toRetailer(r) {
  return {
    id: r.id, name: r.name, phone: r.phone, address: r.address, state: r.state, cityLga: r.city_lga,
    latitude: r.latitude, longitude: r.longitude, isAvailable: r.is_available,
    openingHours: r.opening_hours, status: r.status, statusReason: r.status_reason,
    createdAt: r.created_at, updatedAt: r.updated_at,
  };
}

// Nearby approved + available retailers. Accepts lat/lng/radius (metres) or the
// Flutter map's latitude/longitude/radiusKm. Response: { stations: [...] }.
async function nearbyHandler(req, res) {
  try {
    const q = req.query;
    const lat = v.num(q.lat ?? q.latitude, 'lat', { min: -90, max: 90 });
    const lng = v.num(q.lng ?? q.longitude, 'lng', { min: -180, max: 180 });
    let radiusM = 10000;
    if (q.radius !== undefined) radiusM = v.num(q.radius, 'radius', { min: 100, max: 50000 });
    else if (q.radiusKm !== undefined) radiusM = v.num(q.radiusKm, 'radiusKm', { min: 0.1, max: 50 }) * 1000;
    const limit = q.limit !== undefined ? Math.trunc(v.num(q.limit, 'limit', { min: 1, max: 100 })) : 50;
    const { rows } = await pool.query(
      'select * from public.nearby_retailers($1, $2, $3, $4)',
      [lat, lng, Math.round(radiusM), limit]
    );
    res.set('Cache-Control', 'public, max-age=30');
    res.json({
      stations: rows.map((r) => ({
        id: r.id, name: r.name, phone: r.phone_e164, address: r.address_line,
        latitude: r.latitude, longitude: r.longitude, isAvailable: r.is_available,
        openingHours: r.opening_hours, distanceM: Math.round(r.distance_m),
      })),
    });
  } catch (err) {
    require('./http').sendError(res, err, 'Could not load nearby retailers', 'retailers');
  }
}
router.get('/nearby', nearbyLimiter, nearbyHandler);

// Register as a retailer. Starts as pending; an admin must approve.
router.post('/', writeLimiter, requireAuth, route(async (req, res) => {
  const b = req.body || {};
  const values = [
    req.user.id,
    v.text(b.name, 'name', { min: 2, max: 120 }),
    v.phone(b.phone),
    v.text(b.address, 'address', { min: 3, max: 200 }),
    v.text(b.state, 'state', { min: 2, max: 80, optional: true }),
    v.text(b.cityLga, 'cityLga', { min: 2, max: 80, optional: true }),
    v.num(b.latitude, 'latitude', { min: -90, max: 90 }),
    v.num(b.longitude, 'longitude', { min: -180, max: 180 }),
    v.openingHours(b.openingHours),
  ];
  const { rows } = await pool.query(
    `insert into public.retailers (app_user_id, name, phone_e164, address_line, state, city_lga, latitude, longitude, opening_hours)
     values ($1,$2,$3,$4,$5,$6,$7,$8,$9)
     on conflict (app_user_id) do nothing
     returning ${OWN_COLUMNS}`,
    values
  );
  if (!rows[0]) return res.status(409).json({ error: 'You already have a retailer profile. Use PATCH /retailers/me.' });
  return res.status(201).json({ retailer: toRetailer(rows[0]) });
}));

router.get('/me', requireAuth, route(async (req, res) => {
  const { rows } = await pool.query(`select ${OWN_COLUMNS} from public.retailers where app_user_id = $1`, [req.user.id]);
  if (!rows[0]) return res.status(404).json({ error: 'No retailer profile yet' });
  return res.json({ retailer: toRetailer(rows[0]) });
}));

// Owner updates availability / hours / contact details. Editing address or
// location of an approved retailer sends it back to pending review.
router.patch('/me', writeLimiter, requireAuth, route(async (req, res) => {
  const b = req.body || {};
  const sets = [];
  const vals = [];
  const add = (col, val) => { vals.push(val); sets.push(`${col} = $${vals.length}`); };
  if (b.isAvailable !== undefined) add('is_available', v.bool(b.isAvailable, 'isAvailable'));
  if (b.openingHours !== undefined) add('opening_hours', v.openingHours(b.openingHours));
  if (b.name !== undefined) add('name', v.text(b.name, 'name', { min: 2, max: 120 }));
  if (b.phone !== undefined) add('phone_e164', v.phone(b.phone));
  let relocate = false;
  if (b.address !== undefined) { add('address_line', v.text(b.address, 'address', { min: 3, max: 200 })); relocate = true; }
  if (b.latitude !== undefined || b.longitude !== undefined) {
    add('latitude', v.num(b.latitude, 'latitude', { min: -90, max: 90 }));
    add('longitude', v.num(b.longitude, 'longitude', { min: -180, max: 180 }));
    relocate = true;
  }
  if (!sets.length) throw v.bad('Nothing to update');
  if (relocate || b.name !== undefined) sets.push(`status = case when status = 'rejected' then status else 'pending'::public.retailer_status end`);
  vals.push(req.user.id);
  const { rows } = await pool.query(
    `update public.retailers set ${sets.join(', ')} where app_user_id = $${vals.length} returning ${OWN_COLUMNS}`,
    vals
  );
  if (!rows[0]) return res.status(404).json({ error: 'No retailer profile yet' });
  return res.json({ retailer: toRetailer(rows[0]) });
}));

// ---- Admin
router.get('/admin/pending', requireAuth, requireAdmin, route(async (_req, res) => {
  const { rows } = await pool.query(
    `select ${OWN_COLUMNS} from public.retailers where status = 'pending' order by created_at limit 200`
  );
  res.json({ retailers: rows.map(toRetailer) });
}));

router.post('/:id/review', writeLimiter, requireAuth, requireAdmin, route(async (req, res) => {
  const id = v.uuid(req.params.id);
  const decision = req.body?.decision;
  if (!['approved', 'rejected'].includes(decision)) throw v.bad('decision must be "approved" or "rejected"');
  const reason = v.text(req.body?.reason, 'reason', { min: 2, max: 300, optional: decision === 'approved' });
  const { rows } = await pool.query(
    `update public.retailers set status = $1, status_reason = $2, reviewed_by = $3, reviewed_at = now()
     where id = $4 returning ${OWN_COLUMNS}`,
    [decision, reason, req.user.id, id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'Retailer not found' });
  return res.json({ retailer: toRetailer(rows[0]) });
}));

module.exports = router;
module.exports.nearbyHandler = nearbyHandler;
