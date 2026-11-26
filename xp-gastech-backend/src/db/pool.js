const { Pool } = require('pg');

// On Vercel each serverless instance gets its own pool, so cap it at 1
// connection per instance (Supabase pooler absorbs the fan-out).
// Override with PG_POOL_MAX. Local default stays at pg's 10.
const poolMax = Number(process.env.PG_POOL_MAX) || (process.env.VERCEL ? 1 : 10);

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DATABASE_URL
    ? (process.env.PG_SSL_CA && process.env.PG_SSL_CA.trim()
        ? { ca: process.env.PG_SSL_CA.replace(/\\n/g, '\n'), rejectUnauthorized: true }
        : { rejectUnauthorized: false })
    : undefined,
  connectionTimeoutMillis: 10000,
  max: poolMax,
});

module.exports = { pool };
