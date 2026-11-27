require('dotenv').config();

const express = require('express');
const { pool } = require('./src/db/pool');
const authRoutes = require('./src/routes/auth');
const retailerRoutes = require('./src/routes/retailers');
const businessRoutes = require('./src/routes/businesses');
const meterRoutes = require('./src/routes/meters');
const deviceRoutes = require('./src/routes/devices');
const adminRoutes = require('./src/routes/admin');
const supportRoutes = require('./src/routes/support');
const assistantRoutes = require('./src/routes/assistant');
const docsRoutes = require('./src/routes/docs');
const { securityHeaders, requestLogger } = require('./src/middleware/security');
const { getSmsConfig } = require('./src/services/sendchamp');
const { getEmailConfig } = require('./src/services/sendchampEmail');

const app = express();
const port = Number(process.env.PORT) || 3000;
const host = process.env.HOST || '0.0.0.0';

app.disable('x-powered-by');
// Trust the first proxy hop (Vercel's edge). Required so express-rate-limit
// reads the real client IP from X-Forwarded-For instead of rejecting every
// request; direct local connections are unaffected.
app.set('trust proxy', 1);

// --- CORS (hand-rolled, no extra dependency) ---------------------------------
// Allows any http(s)://localhost:<port> / 127.0.0.1:<port> origin (Flutter web
// dev server on 5050, 8080, …) plus anything listed in CORS_ORIGINS
// (comma-separated, exact match) for deployed front-ends.
const LOCAL_ORIGIN = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/i;
const XP_ORIGIN = /^https:\/\/([a-z0-9-]+\.)?xptechltd\.com$/i;
const VERCEL_ORIGIN = /^https:\/\/[a-z0-9-]+-papagedonlabs-4556s-projects\.vercel\.app$/i;
const extraOrigins = (process.env.CORS_ORIGINS || '')
  .split(',')
  .map((o) => o.trim())
  .filter(Boolean);

function isAllowedOrigin(origin) {
  if (!origin) return false;
  return LOCAL_ORIGIN.test(origin) ||
    XP_ORIGIN.test(origin) ||
    VERCEL_ORIGIN.test(origin) ||
    extraOrigins.includes(origin);
}

app.use(securityHeaders);
app.use(requestLogger);

app.use((req, res, next) => {
  const origin = req.headers.origin;
  if (origin && isAllowedOrigin(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Credentials', 'true');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS');
    res.setHeader(
      'Access-Control-Allow-Headers',
      'Content-Type, Authorization, X-Device-Key, X-Request-Id'
    );
    res.setHeader('Access-Control-Expose-Headers', 'X-Request-Id');
    res.setHeader('Access-Control-Max-Age', '600');
  }
  res.setHeader('Vary', 'Origin');
  if (req.method === 'OPTIONS') {
    return res.sendStatus(origin && isAllowedOrigin(origin) ? 204 : 403);
  }
  next();
});

// The logo upload carries a base64 image, so it gets a larger JSON limit;
// everything else keeps the tight 32kb cap.
const jsonStandard = express.json({ limit: '32kb' });
const jsonLogoUpload = express.json({ limit: '1mb' });
app.use((req, res, next) => {
  const isLogoUpload = req.method === 'POST' && req.path === '/retailers/me/logo';
  return (isLogoUpload ? jsonLogoUpload : jsonStandard)(req, res, next);
});

function healthHandler(_req, res) {
  res.json({
    ok: true,
    apiVersion: 'v1',
    smsConfigured: getSmsConfig().configured,
    emailConfigured: getEmailConfig().configured,
    googleConfigured: Boolean(process.env.GOOGLE_CLIENT_ID),
    geminiConfigured: Boolean(process.env.GEMINI_API_KEY),
    timestamp: new Date().toISOString(),
  });
}

function mountApiRoutes(target) {
  target.get('/health', healthHandler);
  target.use('/', docsRoutes);
  target.use('/auth', authRoutes);
  target.use('/retailers', retailerRoutes);
  target.use('/businesses', businessRoutes);
  target.use('/meters', meterRoutes);
  target.use('/devices', deviceRoutes);
  target.use('/admin', adminRoutes);
  target.use('/support', supportRoutes);
  target.use('/assistant', assistantRoutes);
  // Flutter map contract alias: GET /partner-stations/nearby?latitude&longitude&radiusKm
  target.get('/partner-stations/nearby', retailerRoutes.nearbyHandler);
}

mountApiRoutes(app);

const v1Router = express.Router();
mountApiRoutes(v1Router);
app.use('/api/v1', v1Router);

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
      console.log(getSmsConfig().configured ? 'Sendchamp SMS configured' : 'Sendchamp SMS not configured — set SENDCHAMP_PUBLIC_KEY in .env');
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
