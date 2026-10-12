require('dotenv').config();
const { Client } = require('pg');
const c = new Client({
  connectionString: process.env.DATABASE_URL,
  ssl: { rejectUnauthorized: false },
});
c.connect()
  .then(() => console.log('connected'))
  .catch((e) => console.log(e.message))
  .finally(() => c.end());
