// Meters registered to the signed-in account and offline-reading upload.
//
//   GET    /meters                   list my meters
//   POST   /meters                   register (idempotent per account)
//   PATCH  /meters/:id               rename / set cylinder size
//   DELETE /meters/:id               remove (soft delete; readings kept)
//   POST   /meters/:id/readings      batch upload, idempotent per client_reading_id
//
// Every query is scoped to req.user.id, so a user can never see or write
// another account's meter (unknown or foreign ids both answer 404).
const express = require('express');
const rateLimit = require('express-rate-limit');
const { pool } = require('../db/pool');
const { requireAuth } = require('../middleware/auth');
const v = require('../validation');
const { asyncRoute } = require('./http');

const router = express.Router();
const route = asyncRoute('Meter request failed', 'meters');
router.use(requireAuth);

const MAX_BATCH = 100;
const MAX_METERS_PER_ACCOUNT = 50;
const SOURCES = new Set(['ble_offline', 'ble_live']);

const perUser = (max, windowMs = 60 * 1000) => rateLimit({
  windowMs, max, standardHeaders: true, legacyHeaders: false,
  keyGenerator: (req) => `u:${req.user.id}`,
  message: { error: 'Too many requests. Try again later.' },
});
const writeLimiter = perUser(30);
const uploadLimiter = perUser(60);

function bad(message, extra) {
  const err = new Error(message);
  err.status = 400;
  Object.assign(err, extra);
  return err;
}

/** "98d3:31-aa..." -> "98:D3:31:AA:BB:CC"; throws 400 otherwise. */
function btAddress(raw) {
  if (typeof raw !== 'string') throw bad('btAddress is required');
  const hex = raw.trim().toUpperCase().replace(/[^0-9A-F]/g, '');
  if (hex.length !== 12 || !/^[0-9A-F:\-.\s]+$/i.test(raw.trim())) throw bad('btAddress must be a Bluetooth MAC like 98:D3:31:AA:BB:CC');
  if (hex === '000000000000' || hex === 'FFFFFFFFFFFF') throw bad('btAddress is not a valid device address');
  return hex.match(/.{2}/g).join(':');
}

const COLUMNS = 'id, bt_address, label, cylinder_size_kg, created_at, updated_at, last_reading_at';
const toMeter = (r) => ({
  id: r.id,
  btAddress: r.bt_address,
  label: r.label,
  cylinderSizeKg: r.cylinder_size_kg == null ? null : Number(r.cylinder_size_kg),
  createdAt: r.created_at,
  updatedAt: r.updated_at,
  lastReadingAt: r.last_reading_at,
});

function meterId(req) {
  try {
    return v.uuid(req.params.id, 'meter id');
  } catch (_) {
    const err = new Error('Meter not found');
    err.status = 404;
    throw err;
  }
}

router.get('/', route(async (req, res) => {
  const { rows } = await pool.query(
    `select ${COLUMNS} from public.meters
      where owner_user_id = $1 and deleted_at is null
      order by created_at`, [req.user.id]);
  res.json({ meters: rows.map(toMeter) });
}));

// Register a meter to my account. Same meter again -> 200 with the existing
// record (safe to retry). A meter I removed earlier is revived with its
// history. A meter active on another account -> 409 METER_TAKEN.
router.post('/', writeLimiter, route(async (req, res) => {
  const b = req.body || {};
  const address = btAddress(b.btAddress);
  const label = v.text(b.label, 'label', { min: 1, max: 60, optional: true });
  const size = v.num(b.cylinderSizeKg, 'cylinderSizeKg', { min: 0.5, max: 200, optional: true });

  const client = await pool.connect();
  try {
    await client.query('begin');
    // Serialize concurrent registrations of the same meter.
    await client.query('select pg_advisory_xact_lock(hashtext($1))', [`meter:${address}`]);

    const active = await client.query(
      `select ${COLUMNS}, owner_user_id from public.meters where bt_address = $1 and deleted_at is null`, [address]);
    if (active.rows[0]) {
      await client.query('rollback');
      if (active.rows[0].owner_user_id !== req.user.id) {
        return res.status(409).json({ error: 'This meter is registered to another account.', code: 'METER_TAKEN' });
      }
      return res.status(200).json({ meter: toMeter(active.rows[0]), created: false });
    }

    const count = await client.query(
      'select count(*)::int as n from public.meters where owner_user_id = $1 and deleted_at is null', [req.user.id]);
    if (count.rows[0].n >= MAX_METERS_PER_ACCOUNT) {
      await client.query('rollback');
      return res.status(409).json({ error: `An account can have at most ${MAX_METERS_PER_ACCOUNT} meters.`, code: 'METER_LIMIT' });
    }

    const revived = await client.query(
      `update public.meters
          set deleted_at = null, updated_at = now(),
              label = coalesce($3, label), cylinder_size_kg = coalesce($4, cylinder_size_kg)
        where id = (select id from public.meters
                     where owner_user_id = $1 and bt_address = $2 and deleted_at is not null
                     order by deleted_at desc limit 1)
        returning ${COLUMNS}`, [req.user.id, address, label, size]);
    let row = revived.rows[0];
    if (!row) {
      const ins = await client.query(
        `insert into public.meters (owner_user_id, bt_address, label, cylinder_size_kg)
         values ($1, $2, $3, $4) returning ${COLUMNS}`, [req.user.id, address, label, size]);
      row = ins.rows[0];
    }
    await client.query('commit');
    return res.status(201).json({ meter: toMeter(row), created: true });
  } catch (err) {
    await client.query('rollback').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}));

router.patch('/:id', writeLimiter, route(async (req, res) => {
  const id = meterId(req);
  const b = req.body || {};
  const sets = [];
  const params = [id, req.user.id];
  if ('label' in b) {
    params.push(v.text(b.label, 'label', { min: 1, max: 60, optional: true }));
    sets.push(`label = $${params.length}`);
  }
  if ('cylinderSizeKg' in b) {
    params.push(v.num(b.cylinderSizeKg, 'cylinderSizeKg', { min: 0.5, max: 200, optional: true }));
    sets.push(`cylinder_size_kg = $${params.length}`);
  }
  if (!sets.length) throw bad('Nothing to update (label, cylinderSizeKg)');
  const { rows } = await pool.query(
    `update public.meters set ${sets.join(', ')}, updated_at = now()
      where id = $1 and owner_user_id = $2 and deleted_at is null
      returning ${COLUMNS}`, params);
  if (!rows[0]) return res.status(404).json({ error: 'Meter not found' });
  return res.json({ meter: toMeter(rows[0]) });
}));

router.delete('/:id', writeLimiter, route(async (req, res) => {
  const id = meterId(req);
  const { rowCount } = await pool.query(
    `update public.meters set deleted_at = now(), updated_at = now()
      where id = $1 and owner_user_id = $2 and deleted_at is null`, [id, req.user.id]);
  if (!rowCount) return res.status(404).json({ error: 'Meter not found' });
  return res.status(204).end();
}));

/** Validates one reading; returns a row or throws with a per-item message. */
function parseReading(r) {
  if (!r || typeof r !== 'object' || Array.isArray(r)) throw bad('reading must be an object');
  const clientReadingId = v.uuid(r.client_reading_id, 'client_reading_id');
  const recordedAt = v.isoDate(r.recorded_at, 'recorded_at');
  const percent = v.num(r.percent, 'percent', { min: 0, max: 100, optional: true });
  const weightKg = v.num(r.weight_kg, 'weight_kg', { min: 0, max: 200, optional: true });
  const battery = v.num(r.battery, 'battery', { min: 0, max: 100, optional: true });
  let leak = null;
  if (r.leak_level !== undefined && r.leak_level !== null) {
    if (![0, 1, 2].includes(r.leak_level)) throw bad('leak_level must be 0, 1 or 2');
    leak = r.leak_level;
  }
  if (percent === null && weightKg === null) throw bad('percent or weight_kg is required');
  const source = r.source === undefined ? 'ble_offline' : r.source;
  if (!SOURCES.has(source)) throw bad('source must be ble_offline or ble_live');
  return { clientReadingId, recordedAt, percent, weightKg, battery, leak, source };
}

// Batch upload. Response:
//   accepted: client ids now stored on the server (new + already there) ->
//             the phone marks these synced
//   rejected: [{clientReadingId, error}] invalid items (won't succeed on retry)
//   inserted: how many were new
router.post('/:id/readings', uploadLimiter, route(async (req, res) => {
  const id = meterId(req);
  const list = req.body?.readings;
  if (!Array.isArray(list) || list.length === 0) throw bad('readings must be a non-empty array');
  if (list.length > MAX_BATCH) {
    return res.status(413).json({ error: `At most ${MAX_BATCH} readings per request.`, code: 'BATCH_TOO_LARGE', maxBatch: MAX_BATCH });
  }

  const owned = await pool.query(
    'select id from public.meters where id = $1 and owner_user_id = $2 and deleted_at is null', [id, req.user.id]);
  if (!owned.rows[0]) return res.status(404).json({ error: 'Meter not found' });

  const valid = new Map(); // dedupe within the batch
  const rejected = [];
  for (const item of list) {
    try {
      const row = parseReading(item);
      if (!valid.has(row.clientReadingId)) valid.set(row.clientReadingId, row);
    } catch (err) {
      const cid = item && typeof item.client_reading_id === 'string' ? item.client_reading_id : null;
      rejected.push({ clientReadingId: cid, error: err.message });
    }
  }

  let inserted = 0;
  const rows = [...valid.values()];
  if (rows.length) {
    const client = await pool.connect();
    try {
      await client.query('begin');
      const ins = await client.query(
        `insert into public.meter_readings
           (meter_id, client_reading_id, recorded_at, percent, weight_kg, battery, leak_level, source)
         select $1, t.cid, t.rec, t.pct, t.kg, t.bat, t.leak, t.src
           from unnest($2::uuid[], $3::timestamptz[], $4::numeric[], $5::numeric[], $6::numeric[], $7::smallint[], $8::text[])
                as t(cid, rec, pct, kg, bat, leak, src)
         on conflict (meter_id, client_reading_id) do nothing
         returning client_reading_id`,
        [id,
          rows.map((r) => r.clientReadingId), rows.map((r) => r.recordedAt), rows.map((r) => r.percent),
          rows.map((r) => r.weightKg), rows.map((r) => r.battery), rows.map((r) => r.leak), rows.map((r) => r.source)]);
      inserted = ins.rowCount;
      await client.query(
        `update public.meters
            set last_reading_at = greatest(coalesce(last_reading_at, '-infinity'::timestamptz), $2::timestamptz)
          where id = $1`, [id, rows.reduce((m, r) => (r.recordedAt > m ? r.recordedAt : m), rows[0].recordedAt)]);
      await client.query('commit');
    } catch (err) {
      await client.query('rollback').catch(() => {});
      throw err;
    } finally {
      client.release();
    }
  }

  return res.json({
    accepted: rows.map((r) => r.clientReadingId),
    inserted,
    duplicates: rows.length - inserted,
    rejected,
  });
}));

// Recent readings for one of my meters (newest first).
router.get('/:id/readings', route(async (req, res) => {
  const id = meterId(req);
  const limit = Math.min(500, Math.max(1, Number.parseInt(req.query.limit, 10) || 100));
  const owned = await pool.query(
    'select id from public.meters where id = $1 and owner_user_id = $2 and deleted_at is null', [id, req.user.id]);
  if (!owned.rows[0]) return res.status(404).json({ error: 'Meter not found' });
  const { rows } = await pool.query(
    `select client_reading_id, recorded_at, percent, weight_kg, battery, leak_level, source
       from public.meter_readings where meter_id = $1
      order by recorded_at desc limit $2`, [id, limit]);
  return res.json({
    readings: rows.map((r) => ({
      clientReadingId: r.client_reading_id,
      recordedAt: r.recorded_at,
      percent: r.percent == null ? null : Number(r.percent),
      weightKg: r.weight_kg == null ? null : Number(r.weight_kg),
      battery: r.battery == null ? null : Number(r.battery),
      leakLevel: r.leak_level,
      source: r.source,
    })),
  });
}));

module.exports = router;
module.exports.btAddress = btAddress;
module.exports.parseReading = parseReading;
module.exports.MAX_BATCH = MAX_BATCH;
