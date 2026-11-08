// Demo seed for XP GasTech. Idempotent: only demo-tagged rows are replaced.
// Applies sql/001-003 (iffy on a fresh DB), then seeds:
//   demo user (demo@xp-gastech.demo / DemoPass123!), business, 6 weeks of
//   readings, and 6 approved+available Port Harcourt retailers.
// Usage (needs network to Supabase):  node scripts/seed_demo.js
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
const bcrypt = require('bcryptjs');
const { Client } = require('pg');

const DEMO_EMAIL = 'demo@xp-gastech.demo';
const DEMO_PASSWORD = 'DemoPass123!';

const RETAILERS = [
  { name: 'Demo Gas Point - GRA', phone: '+234700000010', address: '12 Aba Road, GRA Phase 2', lat: 4.8156, lng: 7.0498 },
  { name: 'Demo Gas Point - Woji', phone: '+234700000011', address: '8 Woji Road', lat: 4.8187, lng: 7.0707 },
  { name: 'Demo Gas Point - Trans Amadi', phone: '+234700000012', address: 'Plot 5 Trans Amadi Layout', lat: 4.8091, lng: 7.0389 },
  { name: 'Demo Gas Point - Rumuola', phone: '+234700000013', address: '30 Rumuola Road', lat: 4.8426, lng: 7.0023 },
  { name: 'Demo Gas Point - D-Line', phone: '+234700000014', address: '14 D-Line, Port Harcourt', lat: 4.7928, lng: 7.0 },
  { name: 'Demo Gas Point - Odili', phone: '+234700000015', address: '77 Peter Odili Road', lat: 4.8077, lng: 7.0727 },
];

// [daysAgo, kgLeft] — a 12.5kg cylinder draining over ~6 weeks.
const READINGS = [
  [41, 12.5], [38, 11.6], [34, 10.7], [31, 9.8], [27, 8.9], [24, 8.0],
  [20, 7.1], [17, 6.2], [13, 5.3], [10, 4.4], [6, 3.5], [3, 2.6],
];

async function applySql(client, file) {
  const sql = fs.readFileSync(path.join(__dirname, '..', 'sql', file), 'utf8');
  await client.query(sql);
  console.log('applied', file);
}

(async () => {
  const client = new Client({
    connectionString: process.env.DATABASE_URL,
    ssl: { rejectUnauthorized: false },
    connectionTimeoutMillis: 15000,
  });
  try {
    await client.connect();
    console.log('DB connected');

    for (const f of ['001_users_sms.sql', '002_retailers_nearby_gas.sql', '003_advisor_fixes.sql']) {
      await applySql(client, f);
    }

    const hash = await bcrypt.hash(DEMO_PASSWORD, 10);
    const u = await client.query(
      `insert into public.users (email, password_hash) values ($1, $2)
       on conflict (email) do update set password_hash = excluded.password_hash
       returning id`,
      [DEMO_EMAIL, hash]
    );
    const userId = u.rows[0].id;
    console.log('demo user:', DEMO_EMAIL);

    const b = await client.query(
      `insert into public.businesses (app_user_id, name, address_line, state, city_lga, location)
       values ($1, 'Demo Kitchen', '8 Woji Road, GRA', 'Rivers', 'Port Harcourt',
         extensions.st_setsrid(extensions.st_makepoint(7.0498, 4.8156), 4326)::extensions.geography)
       on conflict (app_user_id) where app_user_id is not null
       do update set name = excluded.name
       returning id`,
      [userId]
    );
    const businessId = b.rows[0].id;
    console.log('demo business ready');

    await client.query('delete from public.gas_readings where business_id = $1', [businessId]);
    for (const [daysAgo, kg] of READINGS) {
      const pct = Math.round((kg / 12.5) * 10000) / 100;
      await client.query(
        `insert into public.gas_readings (business_id, kg_left, percent_left, cylinder_label, recorded_at)
         values ($1, $2, $3, 'Demo 12.5kg', now() - make_interval(days => $4))`,
        [businessId, kg, pct, daysAgo]
      );
    }
    console.log('demo readings:', READINGS.length);

    await client.query(`delete from public.retailers where phone_e164 like '+2347000000%'`);
    await client.query(`delete from public.users where email like 'demo-retailer-%@xp-gastech.demo'`);
    let n = 0;
    for (const r of RETAILERS) {
      n += 1;
      const ru = await client.query(
        `insert into public.users (email) values ($1) returning id`,
        [`demo-retailer-${n}@xp-gastech.demo`]
      );
      await client.query(
        `insert into public.retailers
           (app_user_id, name, phone_e164, address_line, state, city_lga, latitude, longitude, status, is_available)
         values ($1, $2, $3, $4, 'Rivers', 'Port Harcourt', $5, $6, 'approved', true)`,
        [ru.rows[0].id, r.name, r.phone, r.address, r.lat, r.lng]
      );
    }
    console.log('demo retailers:', RETAILERS.length);
    console.log('SEED OK — sign in as', DEMO_EMAIL, '/', DEMO_PASSWORD);
  } catch (e) {
    console.error('SEED FAILED:', e.message.split('\n')[0]);
    process.exitCode = 1;
  } finally {
    await client.end().catch(() => {});
  }
})();
