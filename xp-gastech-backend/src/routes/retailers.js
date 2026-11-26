const express = require('express');
const rateLimit = require('express-rate-limit');
const { pool } = require('../db/pool');
const { requireAuth, requireAdmin } = require('../middleware/auth');
const v = require('../validation');
const { asyncRoute } = require('./http');
const logoStore = require('../services/logoStore');
const { sendEmail, getEmailConfig, esc, layout } = require('../services/sendchampEmail');

async function notifyRetailerReview({ userId, stationName, decision, reason }) {
  if (!userId || !getEmailConfig().configured) return;
  try {
    const { rows } = await pool.query('select email from public.users where id = $1', [userId]);
    const email = rows[0]?.email;
    if (!email) return;
    const { appBaseUrl } = getEmailConfig();
    const approved = decision === 'approved';
    const title = approved ? `${stationName} is now live on XP GAS!` : `Update on ${stationName} verification`;
    const body = approved
      ? `<p style="font-size:15px;line-height:24px;color:#1b2430">Great news! Your gas plant <strong>${esc(stationName)}</strong> has been verified by XP GAS Admin and is now live on the Find Refill map.</p>
         <p style="margin:24px 0"><a href="${esc(appBaseUrl)}" style="display:inline-block;background:#0053BA;color:#ffffff;font-weight:700;padding:12px 24px;border-radius:8px;text-decoration:none">Open Partner Portal</a></p>`
      : `<p style="font-size:15px;line-height:24px;color:#1b2430">Your gas plant submission for <strong>${esc(stationName)}</strong> could not be approved yet.</p>
         ${reason ? `<p style="font-size:14px;color:#991b1b;background:#fef2f2;padding:12px;border-radius:8px"><strong>Reason:</strong> ${esc(reason)}</p>` : ''}
         <p style="font-size:14px;color:#475569">Please update your station details and coordinates in the app to re-submit for review.</p>`;
    await sendEmail({
      to: email,
      subject: title,
      html: layout(title, body),
      text: approved
        ? `${stationName} has been approved by XP GAS Admin and is now live at ${appBaseUrl}.`
        : `${stationName} was not approved. Reason: ${reason || 'Please review your details.'}`,
    });
  } catch (e) {
    console.warn('[retailers] review notification failed:', e && e.message);
  }
}

const router = express.Router();
const route = asyncRoute('Retailer request failed', 'retailers');

const limiter = (max, windowMs = 15 * 60 * 1000) => rateLimit({
  windowMs, max, standardHeaders: true, legacyHeaders: false,
  message: { error: 'Too many requests. Try again later.' },
});
const writeLimiter = limiter(30);
const nearbyLimiter = limiter(60, 60 * 1000);

const OWN_COLUMNS = `id, name, phone_e164 as phone, address_line as address, state, city_lga,
  latitude, longitude, is_available, opening_hours, price_per_kg, logo_url, about,
  status, status_reason, created_at, updated_at`;

function toRetailer(r) {
  return {
    id: r.id, name: r.name, phone: r.phone, address: r.address, state: r.state, cityLga: r.city_lga,
    latitude: r.latitude, longitude: r.longitude, isAvailable: r.is_available,
    openingHours: r.opening_hours, pricePerKg: r.price_per_kg === null ? null : Number(r.price_per_kg),
    logoUrl: r.logo_url ?? null, about: r.about ?? null,
    status: r.status, statusReason: r.status_reason,
    createdAt: r.created_at, updatedAt: r.updated_at,
  };
}

// GasGrid viewport contract: bbox=minLng,minLat,maxLng,maxLat
// (same order as the CHIMDIA-GAS-MAP OpenAPI: minx,miny,maxx,maxy).
// Converted to centre + radius so the existing nearby_retailers()
// PostGIS function is reused unchanged.
function haversineM(lat1, lng1, lat2, lng2) {
  const r = Math.PI / 180;
  const dLat = (lat2 - lat1) * r;
  const dLng = (lng2 - lng1) * r;
  const a = Math.sin(dLat / 2) ** 2
    + Math.cos(lat1 * r) * Math.cos(lat2 * r) * Math.sin(dLng / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(a));
}

function bboxToCenterRadius(bbox) {
  const parts = String(bbox).split(',').map((p) => Number(String(p).trim()));
  if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) {
    throw v.bad('bbox must be "minLng,minLat,maxLng,maxLat"');
  }
  const [minLng, minLat, maxLng, maxLat] = parts;
  if (!(minLat >= -90 && maxLat <= 90 && minLat <= maxLat)) {
    throw v.bad('bbox latitudes must satisfy -90 <= minLat <= maxLat <= 90');
  }
  if (!(minLng >= -180 && maxLng <= 180 && minLng <= maxLng)) {
    throw v.bad('bbox longitudes must satisfy -180 <= minLng <= maxLng <= 180');
  }
  // Half the diagonal covers the whole viewport; clamped to the
  // same 100m-50km window as the radius search.
  const radiusM = Math.min(
    50000, Math.max(100, Math.ceil(haversineM(minLat, minLng, maxLat, maxLng) / 2)));
  return { lat: (minLat + maxLat) / 2, lng: (minLng + maxLng) / 2, radiusM };
}

// Nearby approved retailers. Accepts lat/lng/radius (metres), the
// Flutter map's latitude/longitude/radiusKm, or a GasGrid-style bbox
// viewport. Response: { stations: [...] }.
async function nearbyHandler(req, res) {
  try {
    const q = req.query;
    let lat;
    let lng;
    let radiusM = 50000;
    if (q.bbox !== undefined) {
      ({ lat, lng, radiusM } = bboxToCenterRadius(q.bbox));
    } else {
      lat = v.num(q.lat ?? q.latitude, 'lat', { min: -90, max: 90 });
      lng = v.num(q.lng ?? q.longitude, 'lng', { min: -180, max: 180 });
      if (q.radius !== undefined) radiusM = v.num(q.radius, 'radius', { min: 100, max: 100000 });
      else if (q.radiusKm !== undefined) radiusM = v.num(q.radiusKm, 'radiusKm', { min: 0.1, max: 100 }) * 1000;
    }
    const limit = q.limit !== undefined ? Math.trunc(v.num(q.limit, 'limit', { min: 1, max: 100 })) : 50;
    const { rows } = await pool.query(
      'select * from public.nearby_retailers($1, $2, $3, $4)',
      [lat, lng, Math.round(radiusM), limit]
    );
    res.set('Cache-Control', 'public, max-age=30');
    let stations = rows.map((r) => ({
      id: r.id, name: r.name, phone: r.phone_e164, address: r.address_line,
      latitude: r.latitude, longitude: r.longitude, isAvailable: r.is_available,
      openingHours: r.opening_hours, pricePerKg: r.price_per_kg === null ? null : Number(r.price_per_kg),
      logoUrl: r.logo_url ?? null, about: r.about ?? null,
      distanceM: Math.round(r.distance_m),
    }));

    // Optional client-side filtering / sorting
    if (q.inStock === 'true') {
      stations = stations.filter((s) => s.isAvailable);
    }
    if (q.sortBy === 'price') {
      stations.sort((a, b) => {
        if (a.pricePerKg === null && b.pricePerKg === null) return 0;
        if (a.pricePerKg === null) return 1;
        if (b.pricePerKg === null) return -1;
        return a.pricePerKg - b.pricePerKg;
      });
    } else if (q.sortBy === 'distance') {
      stations.sort((a, b) => (a.distanceM ?? Infinity) - (b.distanceM ?? Infinity));
    }

    res.json({ stations });
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
    v.num(b.pricePerKg, 'pricePerKg', { min: 0, max: 1000000, optional: true }),
    v.text(b.about, 'about', { min: 2, max: 500, optional: true }),
  ];
  const { rows } = await pool.query(
    `insert into public.retailers (app_user_id, name, phone_e164, address_line, state, city_lga, latitude, longitude, opening_hours, price_per_kg, about)
     values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
     on conflict (app_user_id) do nothing
     returning ${OWN_COLUMNS}`,
    values
  );
  if (!rows[0]) return res.status(409).json({ error: 'You already have a retailer profile. Use PATCH /retailers/me.' });
  try {
    await pool.query("update public.users set role = 'retailer' where id = $1 and role = 'consumer'", [req.user.id]);
  } catch (_) { /* non-fatal role update */ }
  return res.status(201).json({ retailer: toRetailer(rows[0]) });
}));

router.get('/me', requireAuth, route(async (req, res) => {
  const { rows } = await pool.query(`select ${OWN_COLUMNS} from public.retailers where app_user_id = $1`, [req.user.id]);
  if (!rows[0]) return res.status(404).json({ error: 'No retailer profile yet' });
  return res.json({ retailer: toRetailer(rows[0]) });
}));

// Pin or ping station coordinates and current price.
// Designed for mobile/map/live-ping workflows. Preserves existing approval status
// so active plants remain visible on the customer map immediately.
async function pinLocationHandler(req, res) {
  const b = req.body || {};
  const lat = v.num(b.latitude ?? b.lat, 'latitude', { min: -90, max: 90 });
  const lng = v.num(b.longitude ?? b.lng, 'longitude', { min: -180, max: 180 });

  const { rows: existing } = await pool.query(
    `select ${OWN_COLUMNS} from public.retailers where app_user_id = $1`,
    [req.user.id]
  );

  if (!existing[0]) {
    // If name and phone are provided, auto-create a profile on first pin
    if (b.name && b.phone) {
      const name = v.text(b.name, 'name', { min: 2, max: 120 });
      const phone = v.phone(b.phone);
      const address = v.text(b.address || 'Address pending verification', 'address', { min: 3, max: 200 });
      const pricePerKg = v.num(b.pricePerKg, 'pricePerKg', { min: 0, max: 1000000, optional: true });
      const isAvailable = b.isAvailable !== undefined ? v.bool(b.isAvailable, 'isAvailable') : true;
      const about = v.text(b.about, 'about', { min: 2, max: 500, optional: true });
      const { rows } = await pool.query(
        `insert into public.retailers (app_user_id, name, phone_e164, address_line, latitude, longitude, price_per_kg, is_available, about, status)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'approved')
         on conflict (app_user_id) do update set
           latitude = excluded.latitude, longitude = excluded.longitude,
           price_per_kg = coalesce(excluded.price_per_kg, public.retailers.price_per_kg),
           is_available = coalesce(excluded.is_available, public.retailers.is_available),
           status = 'approved',
           updated_at = now()
         returning ${OWN_COLUMNS}`,
        [req.user.id, name, phone, address, lat, lng, pricePerKg, isAvailable, about]
      );
      try {
        await pool.query("update public.users set role = 'retailer' where id = $1 and role = 'consumer'", [req.user.id]);
      } catch (_) {}
      return res.status(201).json({
        ok: true,
        message: 'Station registered and location pinned successfully.',
        retailer: toRetailer(rows[0]),
      });
    }
    return res.status(404).json({
      error: 'No retailer profile yet. Register first via POST /retailers or include name and phone to initialize.',
    });
  }

  const sets = [
    'latitude = $1',
    'longitude = $2',
    "status = case when status = 'rejected' then 'rejected' else 'approved' end",
    'updated_at = now()'
  ];
  const vals = [lat, lng];

  if (b.pricePerKg !== undefined) {
    vals.push(v.num(b.pricePerKg, 'pricePerKg', { min: 0, max: 1000000, optional: true }));
    sets.push(`price_per_kg = $${vals.length}`);
  }
  if (b.isAvailable !== undefined) {
    vals.push(v.bool(b.isAvailable, 'isAvailable'));
    sets.push(`is_available = $${vals.length}`);
  }
  if (b.address !== undefined) {
    vals.push(v.text(b.address, 'address', { min: 3, max: 200 }));
    sets.push(`address_line = $${vals.length}`);
  }

  vals.push(req.user.id);
  const { rows } = await pool.query(
    `update public.retailers set ${sets.join(', ')} where app_user_id = $${vals.length} returning ${OWN_COLUMNS}`,
    vals
  );

  return res.json({
    ok: true,
    message: 'Station location and pricing pinned successfully.',
    retailer: toRetailer(rows[0]),
  });
}

router.post('/me/location', writeLimiter, requireAuth, route(pinLocationHandler));
router.post('/me/pin', writeLimiter, requireAuth, route(pinLocationHandler));
router.post('/me/ping', writeLimiter, requireAuth, route(pinLocationHandler));

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
  if (b.pricePerKg !== undefined) add('price_per_kg', v.num(b.pricePerKg, 'pricePerKg', { min: 0, max: 1000000, optional: true }));
  if (b.about !== undefined) add('about', v.text(b.about, 'about', { min: 2, max: 500, optional: true }));
  let relocate = false;
  if (b.address !== undefined) { add('address_line', v.text(b.address, 'address', { min: 3, max: 200 })); relocate = true; }
  if (b.state !== undefined) add('state', v.text(b.state, 'state', { min: 2, max: 80, optional: true }));
  if (b.cityLga !== undefined) add('city_lga', v.text(b.cityLga, 'cityLga', { min: 2, max: 80, optional: true }));
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

// Station logo upload. Body: { imageBase64, contentType }. Stored in the
// Supabase "retailer-logos" bucket; the public URL is saved as logo_url.
// Needs a larger JSON limit than the global 32kb (see server.js).
router.post('/me/logo', writeLimiter, requireAuth, route(async (req, res) => {
  if (!logoStore.isConfigured()) {
    return res.status(503).json({ error: 'Logo uploads are not set up yet. Try again later.' });
  }
  const { rows: existing } = await pool.query(
    'select id from public.retailers where app_user_id = $1', [req.user.id]);
  if (!existing[0]) return res.status(404).json({ error: 'No retailer profile yet' });
  const parsed = logoStore.parseLogoUpload(req.body);
  const { url } = await logoStore.uploadLogo({ userId: req.user.id, ...parsed });
  const { rows } = await pool.query(
    `update public.retailers set logo_url = $1 where app_user_id = $2 returning ${OWN_COLUMNS}`,
    [url, req.user.id]
  );
  return res.json({ retailer: toRetailer(rows[0]) });
}));

// Removes the station logo (profile field cleared, stored file deleted best-effort).
router.delete('/me/logo', writeLimiter, requireAuth, route(async (req, res) => {
  const { rows } = await pool.query(
    `update public.retailers set logo_url = null where app_user_id = $1 returning ${OWN_COLUMNS}`,
    [req.user.id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'No retailer profile yet' });
  await logoStore.deleteLogo(req.user.id);
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
     where id = $4 returning ${OWN_COLUMNS}, app_user_id`,
    [decision, reason, req.user.id, id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'Retailer not found' });
  if (decision === 'approved' && rows[0].app_user_id) {
    try {
      await pool.query("update public.users set role = 'retailer' where id = $1 and role != 'admin'", [rows[0].app_user_id]);
    } catch (_) { /* non-fatal role update */ }
  }
  notifyRetailerReview({
    userId: rows[0].app_user_id,
    stationName: rows[0].name,
    decision,
    reason,
  });
  return res.json({ retailer: toRetailer(rows[0]) });
}));

module.exports = router;
module.exports.nearbyHandler = nearbyHandler;
module.exports.bboxToCenterRadius = bboxToCenterRadius;
module.exports.notifyRetailerReview = notifyRetailerReview;
