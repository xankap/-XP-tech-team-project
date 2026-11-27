const express = require('express');

const router = express.Router();

const openApiSpec = {
  openapi: '3.0.3',
  info: {
    title: 'XP GasTech Hardware & Mobile API',
    version: '1.0.0',
    description:
      'Production API for XP Technology Smart Gas Meter IoT hardware, mobile app, and AI diagnostics.',
  },
  servers: [
    { url: 'https://api.xptechltd.com/api/v1', description: 'Production (v1)' },
    { url: 'https://api.xptechltd.com', description: 'Production (root alias)' },
  ],
  components: {
    securitySchemes: {
      BearerAuth: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT' },
      DeviceKeyAuth: {
        type: 'apiKey',
        in: 'header',
        name: 'X-Device-Key',
        description: 'Generated via POST /meters/{id}/device-key in the mobile app or API.',
      },
    },
  },
  paths: {
    '/health': {
      get: { summary: 'API health & service flags', responses: { 200: { description: 'Healthy' } } },
    },
    '/auth/login': {
      post: { summary: 'Sign in with email/username + password', responses: { 200: { description: 'Access + refresh tokens' } } },
    },
    '/auth/signup': {
      post: { summary: 'Create account & send verification email', responses: { 201: { description: 'Account created' } } },
    },
    '/auth/refresh': {
      post: { summary: 'Rotate refresh token', responses: { 200: { description: 'New tokens' } } },
    },
    '/auth/logout-all': {
      post: { summary: 'Revoke all sessions for current user', security: [{ BearerAuth: [] }], responses: { 200: { description: 'Revoked' } } },
    },
    '/meters': {
      get: { summary: 'List registered meters', security: [{ BearerAuth: [] }], responses: { 200: { description: 'Meters array' } } },
      post: { summary: 'Register Bluetooth/IoT meter by MAC address', security: [{ BearerAuth: [] }], responses: { 201: { description: 'Meter registered' } } },
    },
    '/meters/{id}/device-key': {
      post: { summary: 'Generate or rotate X-Device-Key for direct Wi-Fi/ESP32 telemetry', security: [{ BearerAuth: [] }], responses: { 201: { description: 'Returns plaintext deviceKey once' } } },
    },
    '/devices/me': {
      get: { summary: 'Hardware self-check, calibration & pending command count', security: [{ DeviceKeyAuth: [] }], responses: { 200: { description: 'Device profile' } } },
    },
    '/devices/handshake': {
      post: { summary: 'Hardware boot sync (updates firmware/RSSI, returns calibration + pending commands)', security: [{ DeviceKeyAuth: [] }], responses: { 200: { description: 'Calibration + commands' } } },
    },
    '/devices/telemetry': {
      post: { summary: 'Ingest single or batched readings from hardware (auto leak/battery alerts + returns pending commands)', security: [{ DeviceKeyAuth: [] }], responses: { 201: { description: 'Ingested + pending commands' } } },
    },
    '/devices/events': {
      post: { summary: 'Report hardware diagnostic event (sensor_fault, calibrated, offline_sync, heartbeat)', security: [{ DeviceKeyAuth: [] }], responses: { 201: { description: 'Event logged' } } },
    },
    '/devices/commands/pending': {
      get: { summary: 'Poll and claim pending commands queued for this hardware unit', security: [{ DeviceKeyAuth: [] }], responses: { 200: { description: 'Commands array' } } },
    },
    '/devices/commands/{commandId}/ack': {
      post: { summary: 'Acknowledge command execution (acked | failed)', security: [{ DeviceKeyAuth: [] }], responses: { 200: { description: 'Updated command' } } },
    },
    '/devices/{id}/diagnostics': {
      get: { summary: 'Mobile app: read meter health, latest readings, and recent events', security: [{ BearerAuth: [] }], responses: { 200: { description: 'Diagnostics snapshot' } } },
    },
    '/devices/{id}/calibration': {
      patch: { summary: 'Mobile app: update tareOffsetKg, calibrationFactor, cylinderSizeKg', security: [{ BearerAuth: [] }], responses: { 200: { description: 'Updated meter' } } },
    },
    '/devices/{id}/commands': {
      get: { summary: 'Mobile app: list recent commands sent to hardware', security: [{ BearerAuth: [] }], responses: { 200: { description: 'Commands list' } } },
      post: { summary: 'Mobile app: queue command for hardware (CALIBRATE_EMPTY, TARE, SET_EMPTY, REBOOT, PING, SET_INTERVAL)', security: [{ BearerAuth: [] }], responses: { 201: { description: 'Queued command' } } },
    },
    '/admin/meters': {
      get: { summary: 'Admin: list all fleet meters with latest telemetry & key status', security: [{ BearerAuth: [] }], responses: { 200: { description: 'Meters list' } } },
      post: { summary: 'Admin: provision a meter for a user and optionally issue X-Device-Key', security: [{ BearerAuth: [] }], responses: { 201: { description: 'Provisioned meter + deviceKey' } } },
    },
    '/admin/meters/{id}/device-key': {
      post: { summary: 'Admin: generate or rotate hardware X-Device-Key for any meter', security: [{ BearerAuth: [] }], responses: { 200: { description: 'Returns plaintext deviceKey once' } } },
      delete: { summary: 'Admin: revoke hardware X-Device-Key', security: [{ BearerAuth: [] }], responses: { 200: { description: 'Revoked' } } },
    },
    '/admin/meters/{id}/commands': {
      post: { summary: 'Admin: queue remote command for hardware unit', security: [{ BearerAuth: [] }], responses: { 201: { description: 'Queued command' } } },
    },
    '/assistant/chat': {
      post: { summary: 'Pip AI assistant (Bearer token unlocks Gemini + live meter diagnostics)', responses: { 200: { description: 'AI reply + resources' } } },
    },
  },
};

router.get('/openapi.json', (_req, res) => {
  res.json(openApiSpec);
});

router.get('/docs', (_req, res) => {
  res.type('html').send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>XP GasTech Developer API &amp; Hardware Guide</title>
  <style>
    :root { --navy:#071426; --blue:#0d47a1; --bg:#f8fafc; --ink:#0f172a; --muted:#475569; --line:#e2e8f0; }
    * { box-sizing:border-box; }
    body { margin:0; font-family:Inter,system-ui,-apple-system,sans-serif; background:var(--bg); color:var(--ink); line-height:1.6; }
    header { background:linear-gradient(135deg,var(--navy),var(--blue)); color:#fff; padding:40px 24px; }
    .wrap { max-width:980px; margin:0 auto; }
    h1 { margin:0 0 8px; font-size:28px; letter-spacing:-0.5px; }
    header p { margin:0; color:#cbd5e1; font-size:15px; }
    main { max-width:980px; margin:28px auto 60px; padding:0 24px; display:grid; gap:22px; }
    .card { background:#fff; border:1px solid var(--line); border-radius:14px; padding:24px; }
    h2 { margin:0 0 12px; font-size:18px; color:var(--navy); }
    code, pre { font-family:ui-monospace,SFMono-Regular,Consolas,monospace; font-size:12.5px; }
    pre { background:#0b1220; color:#e2e8f0; padding:16px; border-radius:10px; overflow-x:auto; margin:10px 0 0; }
    table { width:100%; border-collapse:collapse; font-size:13.5px; }
    th, td { text-align:left; padding:10px 8px; border-bottom:1px solid var(--line); vertical-align:top; }
    th { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:0.6px; }
    .badge { display:inline-block; padding:2px 8px; border-radius:6px; font-size:11px; font-weight:700; background:#eff6ff; color:var(--blue); }
    .badge.hw { background:#ecfdf5; color:#065f46; }
  </style>
</head>
<body>
  <header>
    <div class="wrap">
      <h1>XP GasTech Developer &amp; Hardware API</h1>
      <p>Base URL: <code>https://api.xptechltd.com/api/v1</code> · <a href="/api/v1/openapi.json" style="color:#93c5fd;text-decoration:underline;">OpenAPI 3.0 JSON</a></p>
    </div>
  </header>
  <main>
    <section class="card">
      <h2>1. Authentication Overview</h2>
      <p><strong>Mobile App / User:</strong> <code>Authorization: Bearer &lt;jwt&gt;</code> from <code>POST /auth/login</code>.</p>
      <p><strong>Hardware (ESP32 / SIM800 / Wi-Fi Meter):</strong> <code>X-Device-Key: &lt;deviceKey&gt;</code> generated in the mobile app (<em>Settings → Hardware health &amp; IoT key</em>) or via <code>POST /meters/:id/device-key</code>.</p>
    </section>

    <section class="card">
      <h2>2. Hardware Endpoints (<code>X-Device-Key</code>)</h2>
      <table>
        <thead><tr><th>Method &amp; Path</th><th>Purpose</th></tr></thead>
        <tbody>
          <tr><td><span class="badge hw">GET</span> <code>/devices/me</code></td><td>Verify <code>X-Device-Key</code>, fetch calibration &amp; pending command count.</td></tr>
          <tr><td><span class="badge hw">POST</span> <code>/devices/handshake</code></td><td>Send <code>firmwareVersion</code>, <code>hardwareModel</code>, <code>rssi</code> on boot; returns calibration + pending <code>commands</code>.</td></tr>
          <tr><td><span class="badge hw">POST</span> <code>/devices/telemetry</code></td><td>Send single reading or <code>{ readings: [...] }</code>; auto-flags leak/low-battery + returns pending <code>commands</code>.</td></tr>
          <tr><td><span class="badge hw">POST</span> <code>/devices/events</code></td><td>Log <code>sensor_fault</code>, <code>calibrated</code>, <code>offline_sync</code>, or <code>heartbeat</code>.</td></tr>
          <tr><td><span class="badge hw">GET</span> <code>/devices/commands/pending</code></td><td>Poll &amp; claim queued commands from mobile app/admin.</td></tr>
          <tr><td><span class="badge hw">POST</span> <code>/devices/commands/:commandId/ack</code></td><td>Confirm command execution (<code>{ status: "acked" | "failed", message }</code>).</td></tr>
        </tbody>
      </table>
      <pre>curl -X POST https://api.xptechltd.com/api/v1/devices/telemetry \\
  -H "Content-Type: application/json" \\
  -H "X-Device-Key: YOUR_DEVICE_KEY" \\
  -d '{"percent":82,"weightKg":10.25,"battery":94,"leak":0,"rssi":-61}'</pre>
    </section>

    <section class="card">
      <h2>3. Mobile App Endpoints (<code>Bearer &lt;jwt&gt;</code>)</h2>
      <table>
        <thead><tr><th>Method &amp; Path</th><th>Purpose</th></tr></thead>
        <tbody>
          <tr><td><span class="badge">POST</span> <code>/meters</code></td><td>Register meter by <code>btAddress</code> &amp; <code>cylinderSizeKg</code>.</td></tr>
          <tr><td><span class="badge">POST</span> <code>/meters/:id/device-key</code></td><td>Generate or rotate hardware <code>X-Device-Key</code>.</td></tr>
          <tr><td><span class="badge">GET</span> <code>/devices/:id/diagnostics</code></td><td>Get computed health (<code>healthy|warning|critical</code>), readings &amp; events.</td></tr>
          <tr><td><span class="badge">PATCH</span> <code>/devices/:id/calibration</code></td><td>Update <code>tareOffsetKg</code>, <code>calibrationFactor</code>, <code>cylinderSizeKg</code>.</td></tr>
          <tr><td><span class="badge">POST</span> <code>/devices/:id/commands</code></td><td>Queue command for hardware: <code>CALIBRATE_EMPTY</code>, <code>TARE</code>, <code>SET_EMPTY</code>, <code>REBOOT</code>, <code>PING</code>, <code>SET_INTERVAL</code>.</td></tr>
          <tr><td><span class="badge">GET</span> <code>/devices/:id/commands</code></td><td>Check delivery &amp; ack status of queued commands.</td></tr>
        </tbody>
      </table>
    </section>
  </main>
</body>
</html>`);
});

module.exports = router;
