const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

process.env.JWT_SECRET = process.env.JWT_SECRET || 'test-secret';

const jwt = require('jsonwebtoken');
const { app, pool } = require('../server');

const TEST_METER_ID = '11111111-1111-4111-8111-111111111111';
const TEST_USER_ID = '22222222-2222-4222-8222-222222222222';
const TEST_DEVICE_KEY = 'xp_dev_test_key_1234567890abcdef';

test.after(async () => {
  await pool.end();
});

test('security headers and /api/v1/health work as expected', async (t) => {
  const server = app.listen(0);
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;

  const reqId = crypto.randomUUID();
  const res = await fetch(`${base}/api/v1/health`, {
    headers: { 'X-Request-Id': reqId },
  });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('x-request-id'), reqId);
  assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(res.headers.get('x-frame-options'), 'DENY');
  assert.equal(res.headers.get('referrer-policy'), 'strict-origin-when-cross-origin');

  const body = await res.json();
  assert.equal(body.ok, true);
  assert.equal(body.apiVersion, 'v1');
  assert.ok(typeof body.timestamp === 'string');
});

test('CORS preflight allows X-Device-Key and X-Request-Id for allowed origins', async (t) => {
  const server = app.listen(0);
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;

  const res = await fetch(`${base}/devices/telemetry`, {
    method: 'OPTIONS',
    headers: {
      Origin: 'https://xptechltd.com',
      'Access-Control-Request-Method': 'POST',
      'Access-Control-Request-Headers': 'Content-Type, X-Device-Key',
    },
  });
  assert.equal(res.status, 204);
  const allowHeaders = res.headers.get('access-control-allow-headers') || '';
  assert.match(allowHeaders, /X-Device-Key/i);
  assert.match(allowHeaders, /X-Request-Id/i);
  assert.match(res.headers.get('access-control-expose-headers') || '', /X-Request-Id/i);
});

test('POST /devices/telemetry rejects missing device key with 401 and no-store cache', async (t) => {
  const server = app.listen(0);
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;

  const res = await fetch(`${base}/devices/telemetry`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ percent: 80 }),
  });
  assert.equal(res.status, 401);
  assert.equal(res.headers.get('cache-control'), 'no-store');
});

test('POST /devices/handshake updates firmware metadata and returns calibration', async (t) => {
  const origQuery = pool.query.bind(pool);
  const queries = [];
  pool.query = async (sql, params) => {
    queries.push({ sql, params });
    if (sql.includes('where device_key_hash = $1')) {
      return {
        rows: [
          {
            id: TEST_METER_ID,
            owner_user_id: TEST_USER_ID,
            bt_address: '98:D3:31:AA:BB:CC',
            label: 'Kitchen Meter',
            cylinder_size_kg: '12.5',
            tare_offset_kg: '0.25',
            calibration_factor: '1.02',
            firmware_version: '1.0.0',
            hardware_model: 'ESP32-HX711',
            last_reading_at: null,
          },
        ],
      };
    }
    if (sql.includes('update public.meters')) {
      return {
        rows: [
          {
            id: TEST_METER_ID,
            bt_address: '98:D3:31:AA:BB:CC',
            label: 'Kitchen Meter',
            cylinder_size_kg: '12.5',
            tare_offset_kg: '0.25',
            calibration_factor: '1.02',
            firmware_version: '1.2.0',
            hardware_model: 'ESP32-HX711',
            last_rssi: -58,
          },
        ],
      };
    }
    return { rows: [], rowCount: 1 };
  };
  t.after(() => {
    pool.query = origQuery;
  });

  const server = app.listen(0);
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;

  const res = await fetch(`${base}/api/v1/devices/handshake`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Key': TEST_DEVICE_KEY,
    },
    body: JSON.stringify({
      firmwareVersion: '1.2.0',
      hardwareModel: 'ESP32-HX711',
      rssi: -58,
    }),
  });

  assert.equal(res.status, 200);
  const data = await res.json();
  assert.equal(data.ok, true);
  assert.equal(data.meterId, TEST_METER_ID);
  assert.equal(data.cylinderSizeKg, 12.5);
  assert.equal(data.tareOffsetKg, 0.25);
  assert.equal(data.calibrationFactor, 1.02);
  assert.equal(data.firmwareVersion, '1.2.0');
  assert.ok(queries.some((q) => q.sql.includes('insert into public.device_events')));
});

test('POST /devices/telemetry ingests direct reading and flags leak + low battery anomalies', async (t) => {
  const origQuery = pool.query.bind(pool);
  const origConnect = pool.connect.bind(pool);
  const clientQueries = [];

  pool.query = async (sql) => {
    if (sql.includes('where device_key_hash = $1')) {
      return {
        rows: [
          {
            id: TEST_METER_ID,
            owner_user_id: TEST_USER_ID,
            bt_address: '98:D3:31:AA:BB:CC',
            label: 'Kitchen Meter',
            cylinder_size_kg: '12.5',
            tare_offset_kg: '0',
            calibration_factor: '1',
            firmware_version: '1.2.0',
            hardware_model: 'ESP32-HX711',
            last_reading_at: null,
          },
        ],
      };
    }
    return { rows: [], rowCount: 1 };
  };

  pool.connect = async () => ({
    query: async (sql, params) => {
      clientQueries.push({ sql, params });
      return { rows: [], rowCount: 1 };
    },
    release: () => {},
  });

  t.after(() => {
    pool.query = origQuery;
    pool.connect = origConnect;
  });

  const server = app.listen(0);
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;

  const res = await fetch(`${base}/devices/telemetry`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Key': TEST_DEVICE_KEY,
    },
    body: JSON.stringify({
      percent: 42,
      weightKg: 5.25,
      battery: 10,
      leak: 1,
      rssi: -64,
      clientReadingId: crypto.randomUUID(),
    }),
  });

  assert.equal(res.status, 201);
  const data = await res.json();
  assert.equal(data.ok, true);
  assert.equal(data.inserted, 1);
  assert.deepEqual(data.anomalies, ['leak_alert', 'low_battery']);
  assert.ok(clientQueries.some((q) => q.sql.includes("'leak_alert'")));
  assert.ok(clientQueries.some((q) => q.sql.includes("'low_battery'")));
});

test('POST /devices/events validates eventType and persists valid events', async (t) => {
  const origQuery = pool.query.bind(pool);
  pool.query = async (sql) => {
    if (sql.includes('where device_key_hash = $1')) {
      return {
        rows: [
          {
            id: TEST_METER_ID,
            owner_user_id: TEST_USER_ID,
            bt_address: '98:D3:31:AA:BB:CC',
            label: 'Kitchen Meter',
            cylinder_size_kg: '12.5',
          },
        ],
      };
    }
    if (sql.includes('insert into public.device_events')) {
      return {
        rows: [
          {
            id: '33333333-3333-4333-8333-333333333333',
            meter_id: TEST_METER_ID,
            event_type: 'sensor_fault',
            severity: 'warning',
            message: 'HX711 timeout',
            payload: { retries: 3 },
            created_at: new Date().toISOString(),
          },
        ],
      };
    }
    return { rows: [], rowCount: 1 };
  };
  t.after(() => {
    pool.query = origQuery;
  });

  const server = app.listen(0);
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;

  const badRes = await fetch(`${base}/devices/events`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Key': TEST_DEVICE_KEY,
    },
    body: JSON.stringify({ eventType: 'invalid_event' }),
  });
  assert.equal(badRes.status, 400);

  const okRes = await fetch(`${base}/devices/events`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Key': TEST_DEVICE_KEY,
    },
    body: JSON.stringify({
      eventType: 'sensor_fault',
      severity: 'warning',
      message: 'HX711 timeout',
      payload: { retries: 3 },
    }),
  });
  assert.equal(okRes.status, 201);
  const okData = await okRes.json();
  assert.equal(okData.ok, true);
  assert.equal(okData.event.eventType, 'sensor_fault');
  assert.equal(okData.event.severity, 'warning');
});

test('GET /devices/:id/diagnostics computes health and returns readings/events for owner', async (t) => {
  const origQuery = pool.query.bind(pool);
  pool.query = async (sql) => {
    if (sql.includes('from users u where u.id = $1')) {
      return {
        rows: [
          {
            id: TEST_USER_ID,
            email: 'owner@xptechltd.com',
            phone: null,
            username: 'owner',
            role: 'consumer',
            phone_verified_at: null,
            email_verified_at: new Date().toISOString(),
            created_at: new Date().toISOString(),
            session_active: true,
          },
        ],
      };
    }
    if (sql.includes('from public.meters') && sql.includes('where id = $1')) {
      return {
        rows: [
          {
            id: TEST_METER_ID,
            owner_user_id: TEST_USER_ID,
            bt_address: '98:D3:31:AA:BB:CC',
            label: 'Kitchen Meter',
            cylinder_size_kg: '12.5',
            tare_offset_kg: '0',
            calibration_factor: '1',
            firmware_version: '1.2.0',
            hardware_model: 'ESP32-HX711',
            last_rssi: -60,
            last_ip: '127.0.0.1',
            last_reading_at: new Date().toISOString(),
            created_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
          },
        ],
      };
    }
    if (sql.includes('from public.meter_readings')) {
      return {
        rows: [
          {
            id: '44444444-4444-4444-8444-444444444444',
            percent: 65,
            weight_kg: 8.1,
            battery: 88,
            leak_level: 1,
            recorded_at: new Date().toISOString(),
            source: 'device_direct',
          },
        ],
      };
    }
    if (sql.includes('from public.device_events')) {
      return {
        rows: [
          {
            id: '55555555-5555-4555-8555-555555555555',
            meter_id: TEST_METER_ID,
            event_type: 'leak_alert',
            severity: 'critical',
            message: 'Gas leak sensor triggered (level 1)',
            payload: { leakLevel: 1 },
            created_at: new Date().toISOString(),
          },
        ],
      };
    }
    return { rows: [] };
  };
  t.after(() => {
    pool.query = origQuery;
  });

  const server = app.listen(0);
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;
  const token = jwt.sign({ sub: TEST_USER_ID, typ: 'access' }, process.env.JWT_SECRET, {
    expiresIn: '1h',
  });

  const res = await fetch(`${base}/devices/${TEST_METER_ID}/diagnostics`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(res.status, 200);
  const data = await res.json();
  assert.equal(data.ok, true);
  assert.equal(data.health, 'critical');
  assert.equal(data.recentReadings.length, 1);
  assert.equal(data.recentEvents.length, 1);
});

test('GET /admin/diagnostics requires admin authentication', async (t) => {
  const server = app.listen(0);
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;

  const res = await fetch(`${base}/admin/diagnostics`);
  assert.equal(res.status, 401);
});
