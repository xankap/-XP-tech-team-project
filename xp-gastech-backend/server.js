require('dotenv').config();

const express = require('express');
const { pool } = require('./src/db/pool');
const authRoutes = require('./src/routes/auth');
const { getTwilioConfig } = require('./src/services/twilio');

const app = express();
const port = Number(process.env.PORT) || 3000;

app.use(express.json({ limit: '32kb' }));

app.get('/health', (_req, res) => {
  const twilio = getTwilioConfig();
  res.json({
    ok: true,
    twilioConfigured: twilio.configured,
  });
});

app.use('/auth', authRoutes);

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

async function main() {
  await connectDatabase();
  if (process.env.RUN_SERVER === '1') {
    app.listen(port, () => {
      console.log(`XP GasTech API listening on :${port}`);
      const twilio = getTwilioConfig();
      console.log(twilio.configured ? 'Twilio configured' : 'Twilio placeholders only — set TWILIO_* in .env');
    });
  }
}

if (require.main === module) {
  main();
}

module.exports = { app, pool, connectDatabase };
