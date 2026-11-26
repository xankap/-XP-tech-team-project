const crypto = require('crypto');
const { pool } = require('../db/pool');

function hashDeviceKey(key) {
  return crypto.createHash('sha256').update(String(key)).digest('hex');
}

/**
 * Authenticates physical IoT / gas meter hardware using `X-Device-Key`
 * (or `deviceKey` in body for constrained microcontrollers).
 * Attaches `req.device` on success.
 */
async function requireDeviceAuth(req, res, next) {
  try {
    const rawKey = req.get('x-device-key') || req.body?.deviceKey;
    if (typeof rawKey !== 'string' || rawKey.trim().length < 16 || rawKey.trim().length > 128) {
      return res.status(401).json({
        error: 'Missing or invalid X-Device-Key header',
        code: 'DEVICE_AUTH_REQUIRED',
      });
    }

    const keyHash = hashDeviceKey(rawKey.trim());
    const { rows } = await pool.query(
      `select id, owner_user_id, bt_address, label, cylinder_size_kg,
              tare_offset_kg, calibration_factor, firmware_version, hardware_model,
              last_reading_at
         from public.meters
        where device_key_hash = $1 and deleted_at is null`,
      [keyHash]
    );

    const m = rows[0];
    if (!m) {
      return res.status(401).json({
        error: 'Unrecognized or revoked device key',
        code: 'DEVICE_KEY_INVALID',
      });
    }

    req.device = {
      id: m.id,
      ownerUserId: m.owner_user_id,
      btAddress: m.bt_address,
      label: m.label,
      cylinderSizeKg: m.cylinder_size_kg == null ? null : Number(m.cylinder_size_kg),
      tareOffsetKg: m.tare_offset_kg == null ? 0 : Number(m.tare_offset_kg),
      calibrationFactor: m.calibration_factor == null ? 1.0 : Number(m.calibration_factor),
      firmwareVersion: m.firmware_version || null,
      hardwareModel: m.hardware_model || null,
      lastReadingAt: m.last_reading_at,
    };

    return next();
  } catch (err) {
    console.error('[deviceAuth]', err);
    return res.status(500).json({ error: 'Device authentication check failed' });
  }
}

module.exports = { requireDeviceAuth, hashDeviceKey };
