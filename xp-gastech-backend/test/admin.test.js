const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

process.env.JWT_SECRET = 'test-secret';
const DB_URL = process.env.TEST_DATABASE_URL;
if (DB_URL) {
  process.env.DATABASE_URL = DB_URL;
  process.env.PG_POOL_MAX = '1';
}

const jwt = require('jsonwebtoken');

test.after(async () => {
  const { pool } = require('../server');
  await pool.end();
});

test('admin route middleware rejects unauthenticated access', async () => {
  const { app } = require('../server');
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;

  try {
    const res = await fetch(`${base}/admin/stats`);
    assert.equal(res.status, 401);

    const data = await res.json();
    assert.match(data.error, /Authorization header/i);
  } finally {
    server.close();
  }
});

test('admin route rejects non-admin users', async () => {
  const { app } = require('../server');
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;

  try {
    const token = jwt.sign({ sub: crypto.randomUUID(), role: 'consumer' }, process.env.JWT_SECRET);
    const res = await fetch(`${base}/admin/stats`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    // Even if user not found in DB or non-admin, fails with 401 or 403
    assert.ok(res.status === 401 || res.status === 403);
  } finally {
    server.close();
  }
});

test('public support submission validates required fields', async () => {
  const { app } = require('../server');
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;

  try {
    // Missing required fields
    const res = await fetch(`${base}/support`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({}),
    });
    assert.equal(res.status, 400);
    const data = await res.json();
    assert.match(data.error, /required/i);
  } finally {
    server.close();
  }
});

test('assistant chat returns XP GAS calibration guidance and resources', async () => {
  const { app } = require('../server');
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;

  try {
    const res = await fetch(`${base}/assistant/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message: 'How do I calibrate my gas meter?' }),
    });
    assert.equal(res.status, 200);
    const data = await res.json();
    assert.match(data.reply, /calibrat|tare|flat/i);
    assert.ok(Array.isArray(data.resources) && data.resources.length > 0);
  } finally {
    server.close();
  }
});
