const express = require('express');
const { pool } = require('../db/pool');
const { requireAuth } = require('../middleware/auth');
const { requireDeviceAuth } = require('../middleware/deviceAuth');
const { parseReading, MAX_BATCH } = require('./meters');
const v = require('../validation');
const { asyncRoute } = require('./http');

const router = express.Router();
const route = asyncRoute('Device request failed', 'devices');

const ALLOWED_EVENT_TYPES = new Set([
  'boot',
  'heartbeat',
  'leak_alert',
  'low_battery',
  'sensor_fault',
  'calibrated',
  'offline_sync',
]);

const ALLOWED_SEVERITIES = new Set(['info', 'warning', 'critical']);

function extractClientIp(req) {
  const fwd = req.headers['x-forwarded-for'];
  if (typeof fwd === 'string' && fwd.trim()) {
    return fwd.split(',')[0].trim().slice(0, 64);
  }
  return typeof req.ip === 'string' ? req.ip.slice(0, 64) : null;
}

function mapDeviceEvent(row) {
  return {
    id: row.id,
    meterId: row.meter_id,
    eventType: row.event_type,
    severity: row.severity,
    message: row.message,
    payload: row.payload || {},
    createdAt: row.created_at,
  };
}

// POST /devices/handshake — firmware boot / config sync from hardware
router.post(
  '/handshake',
  requireDeviceAuth,
  route(async (req, res) => {
    const body = req.body || {};
    const firmwareVersion =
      body.firmwareVersion === undefined || body.firmwareVersion === null
        ? null
        : v.text(body.firmwareVersion, 'firmwareVersion', { max: 40 });
    const hardwareModel =
      body.hardwareModel === undefined || body.hardwareModel === null
        ? null
        : v.text(body.hardwareModel, 'hardwareModel', { max: 60 });
    const rssi =
      body.rssi === undefined || body.rssi === null
        ? null
        : v.num(body.rssi, 'rssi', { min: -150, max: 0, integer: true });
    const ipAddress = extractClientIp(req);

    const { rows } = await pool.query(
      `update public.meters
          set firmware_version = coalesce($2, firmware_version),
              hardware_model = coalesce($3, hardware_model),
              last_rssi = coalesce($4, last_rssi),
              last_ip = coalesce($5, last_ip),
              updated_at = now()
        where id = $1
        returning id, bt_address, label, cylinder_size_kg, tare_offset_kg,
                  calibration_factor, firmware_version, hardware_model, last_rssi`,
      [req.device.id, firmwareVersion, hardwareModel, rssi, ipAddress]
    );
    const meter = rows[0];

    await pool.query(
      `insert into public.device_events (meter_id, event_type, severity, message, payload)
       values ($1, 'boot', 'info', $2, $3::jsonb)`,
      [
        req.device.id,
        `Device handshake${firmwareVersion ? ` (fw ${firmwareVersion})` : ''}`,
        JSON.stringify({
          firmwareVersion: meter.firmware_version,
          hardwareModel: meter.hardware_model,
          rssi: meter.last_rssi,
          ip: ipAddress,
        }),
      ]
    );

    res.json({
      ok: true,
      meterId: meter.id,
      btAddress: meter.bt_address,
      label: meter.label,
      cylinderSizeKg: Number(meter.cylinder_size_kg),
      tareOffsetKg: Number(meter.tare_offset_kg ?? 0),
      calibrationFactor: Number(meter.calibration_factor ?? 1),
      firmwareVersion: meter.firmware_version,
      hardwareModel: meter.hardware_model,
      serverTime: new Date().toISOString(),
    });
  })
);

// POST /devices/telemetry — single or batched direct hardware telemetry + anomaly detection
router.post(
  '/telemetry',
  requireDeviceAuth,
  route(async (req, res) => {
    const body = req.body || {};
    const rawList = Array.isArray(body.readings) ? body.readings : [body];
    if (rawList.length === 0) {
      throw v.bad('readings must not be empty');
    }
    if (rawList.length > MAX_BATCH) {
      throw v.bad(`Too many readings in batch (max ${MAX_BATCH})`);
    }

    const rssi =
      body.rssi === undefined || body.rssi === null
        ? null
        : v.num(body.rssi, 'rssi', { min: -150, max: 0, integer: true });

    const parsed = rawList.map((item) => {
      if (!item || typeof item !== 'object' || Array.isArray(item)) {
        return parseReading(item);
      }
      return parseReading({
        ...item,
        weight_kg: item.weight_kg ?? item.weightKg,
        leak_level: item.leak_level ?? item.leakLevel ?? item.leak,
        recorded_at: item.recorded_at ?? item.recordedAt ?? new Date().toISOString(),
        client_reading_id: item.client_reading_id ?? item.clientReadingId,
        source: 'device_direct',
      });
    });

    const client = await pool.connect();
    let inserted = 0;
    let duplicates = 0;
    const anomalies = [];
    try {
      await client.query('begin');
      let maxRecordedAt = parsed[0].recordedAt instanceof Date
        ? parsed[0].recordedAt.toISOString()
        : String(parsed[0].recordedAt);
      let hasLeak = false;
      let maxLeakLevel = 0;
      let hasLowBattery = false;
      let minBattery = null;

      for (const r of parsed) {
        const recordedAtIso = r.recordedAt instanceof Date
          ? r.recordedAt.toISOString()
          : String(r.recordedAt);
        if (recordedAtIso > maxRecordedAt) maxRecordedAt = recordedAtIso;
        if (r.leak >= 1) {
          hasLeak = true;
          if (r.leak > maxLeakLevel) maxLeakLevel = r.leak;
        }
        if (r.battery !== null && r.battery <= 15) {
          hasLowBattery = true;
          if (minBattery === null || r.battery < minBattery) minBattery = r.battery;
        }

        const { rowCount } = await client.query(
          `insert into public.meter_readings
             (meter_id, percent, weight_kg, battery, leak_level, recorded_at, source, client_reading_id)
           values ($1, $2, $3, $4, $5, $6, 'device_direct', $7)
           on conflict (meter_id, client_reading_id) do nothing`,
          [
            req.device.id,
            r.percent,
            r.weightKg,
            r.battery,
            r.leak,
            recordedAtIso,
            r.clientReadingId,
          ]
        );
        if (rowCount === 1) inserted += 1;
        else duplicates += 1;
      }

      await client.query(
        `update public.meters
            set last_reading_at = greatest(coalesce(last_reading_at, '-infinity'::timestamptz), $2::timestamptz),
                last_rssi = coalesce($3, last_rssi),
                updated_at = now()
          where id = $1`,
        [req.device.id, maxRecordedAt, rssi]
      );

      if (hasLeak) {
        anomalies.push('leak_alert');
        await client.query(
          `insert into public.device_events (meter_id, event_type, severity, message, payload)
           values ($1, 'leak_alert', 'critical', $2, $3::jsonb)`,
          [
            req.device.id,
            `Gas leak sensor triggered (level ${maxLeakLevel})`,
            JSON.stringify({ leakLevel: maxLeakLevel }),
          ]
        );
      }

      if (hasLowBattery) {
        anomalies.push('low_battery');
        await client.query(
          `insert into public.device_events (meter_id, event_type, severity, message, payload)
           values ($1, 'low_battery', 'warning', $2, $3::jsonb)`,
          [
            req.device.id,
            `Device battery low (${minBattery}%)`,
            JSON.stringify({ battery: minBattery }),
          ]
        );
      }

      await client.query('commit');
    } catch (e) {
      await client.query('rollback');
      throw e;
    } finally {
      client.release();
    }

    res.status(201).json({
      ok: true,
      meterId: req.device.id,
      inserted,
      duplicates,
      anomalies,
      serverTime: new Date().toISOString(),
    });
  })
);

// POST /devices/events — explicit diagnostic event reporting from hardware
router.post(
  '/events',
  requireDeviceAuth,
  route(async (req, res) => {
    const body = req.body || {};
    const eventType = v.text(body.eventType, 'eventType', { min: 2, max: 40 });
    if (!ALLOWED_EVENT_TYPES.has(eventType)) {
      throw v.bad(`eventType must be one of: ${Array.from(ALLOWED_EVENT_TYPES).join(', ')}`);
    }

    const severity =
      body.severity === undefined || body.severity === null
        ? 'info'
        : v.text(body.severity, 'severity', { min: 4, max: 16 });
    if (!ALLOWED_SEVERITIES.has(severity)) {
      throw v.bad('severity must be info, warning, or critical');
    }

    const message =
      body.message === undefined || body.message === null
        ? null
        : v.text(body.message, 'message', { max: 500 });

    let payload = {};
    if (body.payload !== undefined && body.payload !== null) {
      if (typeof body.payload !== 'object' || Array.isArray(body.payload)) {
        throw v.bad('payload must be an object');
      }
      payload = body.payload;
    }

    const { rows } = await pool.query(
      `insert into public.device_events (meter_id, event_type, severity, message, payload)
       values ($1, $2, $3, $4, $5::jsonb)
       returning id, meter_id, event_type, severity, message, payload, created_at`,
      [req.device.id, eventType, severity, message, JSON.stringify(payload)]
    );

    res.status(201).json({
      ok: true,
      event: mapDeviceEvent(rows[0]),
    });
  })
);

// GET /devices/:id/diagnostics — owner or admin inspects device health, readings, and events
router.get(
  '/:id/diagnostics',
  requireAuth,
  route(async (req, res) => {
    const meterId = v.uuid(req.params.id, 'meter id');
    const { rows: meterRows } = await pool.query(
      `select id, owner_user_id, bt_address, label, cylinder_size_kg, tare_offset_kg,
              calibration_factor, firmware_version, hardware_model, last_rssi, last_ip,
              last_reading_at, created_at, updated_at
         from public.meters
        where id = $1 and deleted_at is null`,
      [meterId]
    );
    const meterRow = meterRows[0];
    if (!meterRow) {
      return res.status(404).json({ error: 'Meter not found' });
    }
    if (meterRow.owner_user_id !== req.user.id && req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Forbidden' });
    }

    const [readingsRes, eventsRes] = await Promise.all([
      pool.query(
        `select id, percent, weight_kg, battery, leak_level, recorded_at, source
           from public.meter_readings
          where meter_id = $1
          order by recorded_at desc
          limit 10`,
        [meterId]
      ),
      pool.query(
        `select id, meter_id, event_type, severity, message, payload, created_at
           from public.device_events
          where meter_id = $1
          order by created_at desc
          limit 20`,
        [meterId]
      ),
    ]);

    const recentReadings = readingsRes.rows.map((r) => ({
      id: r.id,
      percent: Number(r.percent),
      weightKg: r.weight_kg === null ? null : Number(r.weight_kg),
      battery: r.battery === null ? null : Number(r.battery),
      leakLevel: Number(r.leak_level),
      recordedAt: r.recorded_at,
      source: r.source,
    }));
    const recentEvents = eventsRes.rows.map(mapDeviceEvent);
    const latestReading = recentReadings[0] || null;

    const cutoff = Date.now() - 24 * 60 * 60 * 1000;
    const recent24h = recentEvents.filter((e) => new Date(e.createdAt).getTime() >= cutoff);
    let health = 'healthy';
    if (
      (latestReading && latestReading.leakLevel >= 1) ||
      recent24h.some((e) => e.severity === 'critical')
    ) {
      health = 'critical';
    } else if (
      (latestReading && latestReading.battery !== null && latestReading.battery <= 15) ||
      recent24h.some((e) => e.severity === 'warning')
    ) {
      health = 'warning';
    }

    res.json({
      ok: true,
      health,
      meter: {
        id: meterRow.id,
        userId: meterRow.owner_user_id,
        btAddress: meterRow.bt_address,
        label: meterRow.label,
        cylinderSizeKg: Number(meterRow.cylinder_size_kg),
        tareOffsetKg: Number(meterRow.tare_offset_kg ?? 0),
        calibrationFactor: Number(meterRow.calibration_factor ?? 1),
        firmwareVersion: meterRow.firmware_version,
        hardwareModel: meterRow.hardware_model,
        lastRssi: meterRow.last_rssi,
        lastIp: meterRow.last_ip,
        lastReadingAt: meterRow.last_reading_at,
        createdAt: meterRow.created_at,
        updatedAt: meterRow.updated_at,
      },
      latestReading,
      recentReadings,
      recentEvents,
    });
  })
);

// PATCH /devices/:id/calibration — owner or admin updates load-cell calibration & cylinder size
router.patch(
  '/:id/calibration',
  requireAuth,
  route(async (req, res) => {
    const meterId = v.uuid(req.params.id, 'meter id');
    const body = req.body || {};

    const hasTare = body.tareOffsetKg !== undefined;
    const hasFactor = body.calibrationFactor !== undefined;
    const hasSize = body.cylinderSizeKg !== undefined;
    if (!hasTare && !hasFactor && !hasSize) {
      throw v.bad('Provide at least one of tareOffsetKg, calibrationFactor, or cylinderSizeKg');
    }

    const tareOffsetKg = hasTare
      ? v.num(body.tareOffsetKg, 'tareOffsetKg', { min: -50, max: 50 })
      : null;
    const calibrationFactor = hasFactor
      ? v.num(body.calibrationFactor, 'calibrationFactor', { min: 0.1, max: 10 })
      : null;
    const cylinderSizeKg = hasSize
      ? v.num(body.cylinderSizeKg, 'cylinderSizeKg', { min: 1, max: 200 })
      : null;

    const { rows: existingRows } = await pool.query(
      `select id, owner_user_id from public.meters where id = $1 and deleted_at is null`,
      [meterId]
    );
    const existing = existingRows[0];
    if (!existing) {
      return res.status(404).json({ error: 'Meter not found' });
    }
    if (existing.owner_user_id !== req.user.id && req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Forbidden' });
    }

    const { rows } = await pool.query(
      `update public.meters
          set tare_offset_kg = coalesce($2, tare_offset_kg),
              calibration_factor = coalesce($3, calibration_factor),
              cylinder_size_kg = coalesce($4, cylinder_size_kg),
              updated_at = now()
        where id = $1
        returning id, bt_address, label, cylinder_size_kg, tare_offset_kg, calibration_factor`,
      [meterId, tareOffsetKg, calibrationFactor, cylinderSizeKg]
    );
    const updated = rows[0];

    await Promise.all([
      pool.query(
        `insert into public.device_events (meter_id, event_type, severity, message, payload)
         values ($1, 'calibrated', 'info', 'Calibration updated via API', $2::jsonb)`,
        [
          meterId,
          JSON.stringify({
            tareOffsetKg: Number(updated.tare_offset_kg),
            calibrationFactor: Number(updated.calibration_factor),
            cylinderSizeKg: Number(updated.cylinder_size_kg),
            updatedBy: req.user.id,
          }),
        ]
      ),
      pool.query(
        `insert into public.audit_logs (actor_user_id, action, target_type, target_id, metadata)
         values ($1, 'meter.calibrated', 'meter', $2, $3::jsonb)`,
        [
          req.user.id,
          meterId,
          JSON.stringify({
            tareOffsetKg: Number(updated.tare_offset_kg),
            calibrationFactor: Number(updated.calibration_factor),
            cylinderSizeKg: Number(updated.cylinder_size_kg),
          }),
        ]
      ),
    ]);

    res.json({
      ok: true,
      meter: {
        id: updated.id,
        btAddress: updated.bt_address,
        label: updated.label,
        cylinderSizeKg: Number(updated.cylinder_size_kg),
        tareOffsetKg: Number(updated.tare_offset_kg),
        calibrationFactor: Number(updated.calibration_factor),
      },
    });
  })
);

module.exports = router;
