require('dotenv').config();

const express = require('express');
const { pool } = require('./src/db/pool');
const authRoutes = require('./src/routes/auth');
const retailerRoutes = require('./src/routes/retailers');
const businessRoutes = require('./src/routes/businesses');
const { getTwilioConfig } = require('./src/services/twilio');

const app = express();
const port = Number(process.env.PORT) || 3000;
const host = process.env.HOST || '0.0.0.0';

app.disable('x-powered-by');

// --- CORS (hand-rolled, no extra dependency) ---------------------------------
// Allows any http(s)://localhost:<port> / 127.0.0.1:<port> origin (Flutter web
// dev server on 5050, 8080, …) plus anything listed in CORS_ORIGINS
// (comma-separated, exact match) for deployed front-ends.
const LOCAL_ORIGIN = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/i;
const extraOrigins = (process.env.CORS_ORIGINS || '')
  .split(',')
  .map((o) => o.trim())
  .filter(Boolean);

function isAllowedOrigin(origin) {
  return LOCAL_ORIGIN.test(origin) || extraOrigins.includes(origin);
}

app.use((req, res, next) => {
  const origin = req.headers.origin;
  if (origin && isAllowedOrigin(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Credentials', 'true');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    res.setHeader('Access-Control-Max-Age', '600');
  }
  res.setHeader('Vary', 'Origin');
  if (req.method === 'OPTIONS') {
    return res.sendStatus(origin && isAllowedOrigin(origin) ? 204 : 403);
  }
  next();
});

app.use(express.json({ limit: '32kb' }));

app.get('/health', (_req, res) => {
  const twilio = getTwilioConfig();
  res.json({
    ok: true,
    twilioConfigured: twilio.configured,
    googleConfigured: Boolean(process.env.GOOGLE_CLIENT_ID),
  });
});

app.use('/auth', authRoutes);
app.use('/retailers', retailerRoutes);
app.use('/businesses', businessRoutes);
// Flutter map contract alias: GET /partner-stations/nearby?latitude&longitude&radiusKm
app.get('/partner-stations/nearby', retailerRoutes.nearbyHandler);

// JSON 404 for unknown routes.
app.use((_req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// JSON error handler (malformed JSON bodies, oversized payloads, unexpected throws).
// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  if (err.type === 'entity.parse.failed') {
    return res.status(400).json({ error: 'Malformed JSON body' });
  }
  if (err.type === 'entity.too.large') {
    return res.status(413).json({ error: 'Request body too large' });
  }
  console.error('Unhandled error:', err);
  res.status(err.status || 500).json({ error: 'Internal server error' });
});

async function connectDatabase() {
  try {
    const client = await pool.connect();
    await client.query('select 1');
    client.release();
    console.log('Database connected');
    return true;
  } catch (err) {
    console.error('Database connection failed:', err.message);
    return false;
  }
}

// Keep the process alive on stray async errors instead of silently dying.
process.on('unhandledRejection', (reason) => {
  console.error('Unhandled promise rejection:', reason);
});

async function main() {
  await connectDatabase();
  if (process.env.RUN_SERVER === '1') {
    const server = app.listen(port, host, () => {
      console.log(`XP GasTech API listening on http://${host}:${port}`);
      const twilio = getTwilioConfig();
      console.log(twilio.configured ? 'Twilio configured' : 'Twilio not fully configured — set TWILIO_* in .env');
      console.log(process.env.GOOGLE_CLIENT_ID ? 'Google OAuth configured' : 'GOOGLE_CLIENT_ID missing — Google sign-in disabled');
    });
    server.on('error', (err) => {
      if (err.code === 'EADDRINUSE') {
        console.error(`Port ${port} is already in use — another backend is probably running.`);
      } else {
        console.error('Server error:', err);
      }
      process.exit(1);
    });
    const shutdown = () => {
      server.close(() => pool.end().finally(() => process.exit(0)));
      setTimeout(() => process.exit(0), 5000).unref();
    };
    process.on('SIGINT', shutdown);
    process.on('SIGTERM', shutdown);
  }
}

if (require.main === module) {
  main();
}

module.exports = { app, pool, connectDatabase };
