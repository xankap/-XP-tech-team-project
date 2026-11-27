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

test('POST /auth/logout-all and DELETE /auth/me require Bearer auth', async (t) => {
  const server = app.listen(0);
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;

  const r1 = await fetch(`${base}/auth/logout-all`, { method: 'POST' });
  assert.equal(r1.status, 401);

  const r2 = await fetch(`${base}/auth/me`, { method: 'DELETE' });
  assert.equal(r2.status, 401);
});

test('POST /retailers/me/pin creates pending station without self-approval', async (t) => {
  const origQuery = pool.query.bind(pool);
  const queries = [];
  pool.query = async (sql, params) => {
    queries.push({ sql, params });
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
    if (sql.includes('from public.retailers where app_user_id = $1')) {
      return { rows: [] };
    }
    if (sql.includes('insert into public.retailers')) {
      return {
        rows: [
          {
            id: '66666666-6666-4666-8666-666666666666',
            name: 'Test Plant',
            phone_e164: '+2348012345678',
            address_line: '1 Test St',
            state: null,
            city_lga: null,
            latitude: 6.5,
            longitude: 3.3,
            opening_hours: null,
            is_available: true,
            price_per_kg: 1200,
            logo_url: null,
            about: null,
            status: 'pending',
            status_reason: null,
            created_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
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

  const res = await fetch(`${base}/retailers/me/pin`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      name: 'Test Plant',
      phone: '+2348012345678',
      latitude: 6.5,
      longitude: 3.3,
      pricePerKg: 1200,
    }),
  });

  assert.equal(res.status, 201);
  const data = await res.json();
  assert.equal(data.retailer.status, 'pending');
  assert.ok(!queries.some((q) => q.sql.includes("set role = 'retailer'")));
  assert.ok(!queries.some((q) => q.sql.includes("'approved'")));
});

test('GET /devices/me returns hardware profile and pendingCommandsCount', async (t) => {
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
            tare_offset_kg: '0.25',
            calibration_factor: '1.02',
            firmware_version: '1.2.0',
            hardware_model: 'ESP32-HX711',
            last_reading_at: null,
          },
        ],
      };
    }
    if (sql.includes('count(*)::int as pending_commands')) {
      return { rows: [{ pending_commands: 2 }] };
    }
    return { rows: [] };
  };
  t.after(() => {
    pool.query = origQuery;
  });

  const server = app.listen(0);
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;

  const res = await fetch(`${base}/api/v1/devices/me`, {
    headers: { 'X-Device-Key': TEST_DEVICE_KEY },
  });
  assert.equal(res.status, 200);
  const data = await res.json();
  assert.equal(data.ok, true);
  assert.equal(data.meterId, TEST_METER_ID);
  assert.equal(data.pendingCommandsCount, 2);
});

test('device command lifecycle: queue, poll pending, ack, and list', async (t) => {
  const origQuery = pool.query.bind(pool);
  const cmdId = '77777777-7777-4777-8777-777777777777';
  const now = new Date().toISOString();

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
            email_verified_at: now,
            created_at: now,
            session_active: true,
          },
        ],
      };
    }
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
    if (sql.includes('select id, owner_user_id from public.meters')) {
      return { rows: [{ id: TEST_METER_ID, owner_user_id: TEST_USER_ID }] };
    }
    if (sql.includes('insert into public.device_commands')) {
      return {
        rows: [
          {
            id: cmdId,
            meter_id: TEST_METER_ID,
            command: 'TARE',
            payload: { reason: 'empty_cylinder' },
            status: 'pending',
            ack_message: null,
            delivered_at: null,
            acked_at: null,
            created_at: now,
          },
        ],
      };
    }
    if (sql.includes("set status = 'delivered'")) {
      return {
        rows: [
          {
            id: cmdId,
            meter_id: TEST_METER_ID,
            command: 'TARE',
            payload: { reason: 'empty_cylinder' },
            status: 'delivered',
            delivered_at: now,
            created_at: now,
          },
        ],
      };
    }
    if (sql.includes('set status = $3')) {
      return {
        rows: [
          {
            id: cmdId,
            meter_id: TEST_METER_ID,
            command: 'TARE',
            payload: { reason: 'empty_cylinder' },
            status: 'acked',
            ack_message: 'Tare complete',
            delivered_at: now,
            acked_at: now,
            created_at: now,
          },
        ],
      };
    }
    if (sql.includes('from public.device_commands') && sql.includes('order by created_at desc')) {
      return {
        rows: [
          {
            id: cmdId,
            meter_id: TEST_METER_ID,
            command: 'TARE',
            payload: { reason: 'empty_cylinder' },
            status: 'acked',
            ack_message: 'Tare complete',
            delivered_at: now,
            acked_at: now,
            created_at: now,
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

  const badRes = await fetch(`${base}/api/v1/devices/${TEST_METER_ID}/commands`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ command: 'SELF_DESTRUCT' }),
  });
  assert.equal(badRes.status, 400);

  const qRes = await fetch(`${base}/api/v1/devices/${TEST_METER_ID}/commands`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ command: 'tare', payload: { reason: 'empty_cylinder' } }),
  });
  assert.equal(qRes.status, 201);
  const qData = await qRes.json();
  assert.equal(qData.command.command, 'TARE');
  assert.equal(qData.command.status, 'pending');

  const pRes = await fetch(`${base}/api/v1/devices/commands/pending`, {
    headers: { 'X-Device-Key': TEST_DEVICE_KEY },
  });
  assert.equal(pRes.status, 200);
  const pData = await pRes.json();
  assert.equal(pData.commands.length, 1);
  assert.equal(pData.commands[0].status, 'delivered');

  const aRes = await fetch(`${base}/api/v1/devices/commands/${cmdId}/ack`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Device-Key': TEST_DEVICE_KEY },
    body: JSON.stringify({ status: 'acked', message: 'Tare complete' }),
  });
  assert.equal(aRes.status, 200);
  const aData = await aRes.json();
  assert.equal(aData.command.status, 'acked');
  assert.equal(aData.command.ackMessage, 'Tare complete');

  const lRes = await fetch(`${base}/api/v1/devices/${TEST_METER_ID}/commands`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(lRes.status, 200);
  const lData = await lRes.json();
  assert.equal(lData.commands.length, 1);
  assert.equal(lData.commands[0].status, 'acked');
});

test('GET /api/v1/openapi.json and /api/v1/docs serve API specification and HTML guide', async (t) => {
  const server = app.listen(0);
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;

  const specRes = await fetch(`${base}/api/v1/openapi.json`);
  assert.equal(specRes.status, 200);
  const spec = await specRes.json();
  assert.equal(spec.openapi, '3.0.3');
  assert.ok(spec.paths['/devices/commands/pending']);

  const docsRes = await fetch(`${base}/api/v1/docs`);
  assert.equal(docsRes.status, 200);
  assert.match(docsRes.headers.get('content-type') || '', /text\/html/);
  const html = await docsRes.text();
  assert.match(html, /XP GasTech Developer/);
});

test('admin can generate, revoke X-Device-Key and queue commands for any meter', async (t) => {
  const origQuery = pool.query.bind(pool);
  const now = new Date().toISOString();
  const queries = [];

  pool.query = async (sql, params) => {
    queries.push({ sql, params });
    if (sql.includes('from users u where u.id = $1')) {
      return {
        rows: [
          {
            id: TEST_USER_ID,
            email: 'admin@xptechltd.com',
            phone: null,
            username: 'admin',
            role: 'admin',
            phone_verified_at: null,
            email_verified_at: now,
            created_at: now,
            session_active: true,
          },
        ],
      };
    }
    if (sql.includes('update public.meters') && sql.includes('set device_key_hash = $1')) {
      return {
        rows: [
          {
            id: TEST_METER_ID,
            bt_address: '98:D3:31:AA:BB:CC',
            label: 'Kitchen Meter',
            owner_user_id: TEST_USER_ID,
          },
        ],
      };
    }
    if (sql.includes('update public.meters') && sql.includes('set device_key_hash = null')) {
      return { rows: [{ id: TEST_METER_ID, bt_address: '98:D3:31:AA:BB:CC' }] };
    }
    if (sql.includes('select id from public.meters where id = $1')) {
      return { rows: [{ id: TEST_METER_ID }] };
    }
    if (sql.includes('insert into public.device_commands')) {
      return {
        rows: [
          {
            id: '88888888-8888-4888-8888-888888888888',
            meter_id: TEST_METER_ID,
            command: 'PING',
            payload: {},
            status: 'pending',
            created_at: now,
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
  const adminToken = jwt.sign({ sub: TEST_USER_ID, typ: 'access' }, process.env.JWT_SECRET, {
    expiresIn: '1h',
  });

  const genRes = await fetch(`${base}/api/v1/admin/meters/${TEST_METER_ID}/device-key`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${adminToken}` },
  });
  assert.equal(genRes.status, 200);
  const genData = await genRes.json();
  assert.equal(genData.ok, true);
  assert.match(genData.deviceKey, /^xpdev_[0-9a-f]{48}$/);
  assert.equal(genData.endpoints.telemetry, '/api/v1/devices/telemetry');

  const cmdRes = await fetch(`${base}/api/v1/admin/meters/${TEST_METER_ID}/commands`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${adminToken}` },
    body: JSON.stringify({ command: 'PING' }),
  });
  assert.equal(cmdRes.status, 201);
  const cmdData = await cmdRes.json();
  assert.equal(cmdData.command.command, 'PING');

  const revRes = await fetch(`${base}/api/v1/admin/meters/${TEST_METER_ID}/device-key`, {
    method: 'DELETE',
    headers: { Authorization: `Bearer ${adminToken}` },
  });
  assert.equal(revRes.status, 200);
  const revData = await revRes.json();
  assert.equal(revData.revoked, true);
  assert.ok(queries.some((q) => q.sql.includes('insert into public.audit_logs')));
});
