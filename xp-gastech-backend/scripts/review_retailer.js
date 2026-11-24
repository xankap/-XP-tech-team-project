// Admin helper for the gas station / LPG plant review queue.
// Lists pending retailers and records approve/reject decisions, mirroring
// POST /retailers/:id/review (status, status_reason, reviewed_by, reviewed_at).
//
// Usage:
//   node scripts/review_retailer.js [list] [--status pending|approved|rejected] [--limit 50]
//   node scripts/review_retailer.js review --id <retailer-uuid> --decision approved|rejected [--reason "..."] [--by <admin-user-uuid>]
//   node scripts/review_retailer.js --help
//
// Needs DATABASE_URL (reads xp-gastech-backend/.env like the other scripts).
const path = require('path');
const { Client } = require('pg');

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DECISIONS = ['approved', 'rejected'];
const STATUSES = ['pending', 'approved', 'rejected'];

const USAGE = `review_retailer.js — approve or reject gas plant listings

List the review queue (default):
  node scripts/review_retailer.js [list] [--status pending] [--limit 50]

Record a decision (mirrors POST /retailers/:id/review):
  node scripts/review_retailer.js review --id <retailer-uuid> --decision approved|rejected [--reason "..."] [--by <admin-user-uuid>]

  --reason  required when rejecting (2-300 chars), optional when approving
  --by      admin user id recorded as reviewed_by (must exist in public.users)

Other:
  node scripts/review_retailer.js --help`;

function usageError(message) {
  const err = new Error(message);
  err.usage = true;
  return err;
}

function asUuid(value, field) {
  if (typeof value !== 'string' || !UUID_RE.test(value)) {
    throw usageError(`${field} must be a valid uuid (got ${JSON.stringify(value) ?? 'nothing'})`);
  }
  return value.toLowerCase();
}

function asReason(value, decision) {
  if (value === undefined || value === null || value === '') {
    if (decision === 'rejected') throw usageError('--reason is required when rejecting (2-300 chars)');
    return null;
  }
  const t = String(value).trim().replace(/\s+/g, ' ');
  if (t.length < 2 || t.length > 300) throw usageError('--reason must be 2-300 characters');
  return t;
}

// Pure argv parser (no I/O) so unit tests can cover the CLI contract.
function parseArgs(argv) {
  const args = [...argv];
  const opts = { command: 'list', status: 'pending', limit: 50 };
  const positional = [];

  for (let i = 0; i < args.length; i += 1) {
    const a = args[i];
    if (a === '--help' || a === '-h') return { ...opts, command: 'help' };
    if (a.startsWith('--')) {
      const eq = a.indexOf('=');
      const key = eq === -1 ? a.slice(2) : a.slice(2, eq);
      const val = eq === -1 ? args[i + 1] : a.slice(eq + 1);
      if (eq === -1) i += 1;
      if (val === undefined || String(val).startsWith('--')) {
        throw usageError(`--${key} needs a value`);
      }
      if (!['id', 'decision', 'reason', 'by', 'status', 'limit'].includes(key)) {
        throw usageError(`unknown option --${key}`);
      }
      opts[key] = String(val);
      continue;
    }
    positional.push(a);
  }

  if (positional.length > 1) throw usageError(`unexpected arguments: ${positional.slice(1).join(' ')}`);
  if (positional.length === 1) {
    if (!['list', 'review', 'help'].includes(positional[0])) {
      throw usageError(`unknown command "${positional[0]}" (expected "list" or "review")`);
    }
    opts.command = positional[0];
  }
  if (opts.command === 'help') return opts;

  if (opts.command === 'list') {
    if (!STATUSES.includes(opts.status)) {
      throw usageError(`--status must be one of ${STATUSES.join('|')} (got ${JSON.stringify(opts.status)})`);
    }
    const limit = Number(opts.limit);
    if (!Number.isInteger(limit) || limit < 1 || limit > 200) {
      throw usageError('--limit must be an integer between 1 and 200');
    }
    opts.limit = limit;
    return opts;
  }

  // review
  opts.id = asUuid(opts.id, '--id');
  if (!DECISIONS.includes(opts.decision)) {
    throw usageError(`--decision must be "approved" or "rejected" (got ${JSON.stringify(opts.decision)})`);
  }
  opts.reason = asReason(opts.reason, opts.decision);
  opts.by = opts.by === undefined ? null : asUuid(opts.by, '--by');
  return opts;
}

function printRow(r) {
  console.log(`- ${r.id} | ${r.status} | avail=${r.is_available ? 'yes' : 'no'} | ${r.name}`);
  console.log(`  ${r.phone_e164} | ${r.address_line}${r.city_lga ? `, ${r.city_lga}` : ''}${r.state ? `, ${r.state}` : ''}`);
  console.log(`  ${Number(r.latitude).toFixed(6)}, ${Number(r.longitude).toFixed(6)} | created ${r.created_at.toISOString()}`);
  if (r.status_reason) console.log(`  reason: ${r.status_reason}`);
}

async function listRetailers(client, { status, limit }) {
  const { rows } = await client.query(
    `select id, name, phone_e164, address_line, state, city_lga, latitude, longitude,
            is_available, status, status_reason, created_at
       from public.retailers where status = $1 order by created_at limit $2`,
    [status, limit]
  );
  if (!rows.length) {
    console.log(`No ${status} retailers.`);
    return;
  }
  console.log(`${rows.length} ${status} retailer(s):`);
  for (const r of rows) printRow(r);
}

async function reviewRetailer(client, { id, decision, reason, by }) {
  if (by) {
    const { rows } = await client.query('select id, role from public.users where id = $1', [by]);
    if (!rows[0]) throw new Error(`--by user ${by} does not exist in public.users`);
    if (rows[0].role !== 'admin') {
      console.warn(`warning: --by user ${by} has role "${rows[0].role}" (expected "admin")`);
    }
  }
  const { rows } = await client.query(
    `update public.retailers set status = $1, status_reason = $2, reviewed_by = $3, reviewed_at = now()
     where id = $4
     returning id, name, phone_e164, address_line, state, city_lga, latitude, longitude,
               is_available, status, status_reason, created_at, app_user_id`,
    [decision, reason, by, id]
  );
  if (!rows[0]) {
    throw new Error(`retailer ${id} not found`);
  }
  if (decision === 'approved' && rows[0].app_user_id) {
    try {
      await client.query("update public.users set role = 'retailer' where id = $1", [rows[0].app_user_id]);
    } catch (_) {}
  }
  console.log(`Retailer ${decision}:`);
  printRow(rows[0]);
}

async function main(argv) {
  require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
  let opts;
  try {
    opts = parseArgs(argv);
  } catch (err) {
    console.error(`Error: ${err.message}\n`);
    console.error(USAGE);
    process.exitCode = 1;
    return;
  }
  if (opts.command === 'help') {
    console.log(USAGE);
    return;
  }
  if (!process.env.DATABASE_URL) {
    console.error('Error: DATABASE_URL is not set (add it to xp-gastech-backend/.env)');
    process.exitCode = 1;
    return;
  }
  const client = new Client({
    connectionString: process.env.DATABASE_URL,
    ssl: { rejectUnauthorized: false },
    connectionTimeoutMillis: 15000,
  });
  try {
    await client.connect();
    if (opts.command === 'list') await listRetailers(client, opts);
    else await reviewRetailer(client, opts);
  } catch (err) {
    console.error(`Error: ${err.message}`);
    process.exitCode = 1;
  } finally {
    await client.end().catch(() => {});
  }
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = { parseArgs, USAGE };
