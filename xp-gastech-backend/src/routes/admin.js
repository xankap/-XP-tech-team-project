const express = require('express');
const { pool } = require('../db/pool');
const { requireAuth, requireAdmin } = require('../middleware/auth');
const v = require('../validation');
const { asyncRoute } = require('./http');
const { notifyRetailerReview } = require('./retailers');

const router = express.Router();
const route = asyncRoute('Admin request failed', 'admin');

// All endpoints in /admin require an authenticated admin user.
router.use(requireAuth, requireAdmin);

function formatRetailer(r) {
  return {
    id: r.id,
    appUserId: r.app_user_id,
    name: r.name,
    phone: r.phone_e164 || r.phone,
    address: r.address_line || r.address,
    state: r.state,
    cityLga: r.city_lga,
    latitude: r.latitude === null ? null : Number(r.latitude),
    longitude: r.longitude === null ? null : Number(r.longitude),
    isAvailable: r.is_available,
    openingHours: r.opening_hours,
    pricePerKg: r.price_per_kg === null ? null : Number(r.price_per_kg),
    logoUrl: r.logo_url ?? null,
    about: r.about ?? null,
    status: r.status,
    statusReason: r.status_reason,
    reviewedBy: r.reviewed_by ?? null,
    reviewedAt: r.reviewed_at ?? null,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
    ownerEmail: r.owner_email ?? null,
    ownerUsername: r.owner_username ?? null,
    ownerPhone: r.owner_phone ?? null,
  };
}

// 1. GET /admin/stats
router.get('/stats', route(async (_req, res) => {
  const [retailersRes, usersRes, metersRes, readingsRes, supportRes] = await Promise.all([
    pool.query(`
      select 
        count(*)::int as total,
        count(*) filter (where status = 'pending')::int as pending,
        count(*) filter (where status = 'approved')::int as approved,
        count(*) filter (where status = 'rejected')::int as rejected
      from public.retailers
    `),
    pool.query(`
      select 
        count(*)::int as total,
        count(*) filter (where role = 'consumer')::int as consumer,
        count(*) filter (where role = 'retailer')::int as retailer,
        count(*) filter (where role = 'admin')::int as admin
      from public.users
    `),
    pool.query(`
      select 
        count(*)::int as total,
        count(*) filter (where deleted_at is null)::int as active,
        count(*) filter (where deleted_at is null and last_reading_at > now() - interval '7 days')::int as online_recent
      from public.meters
    `),
    pool.query(`
      select count(*)::int as total from public.meter_readings
    `),
    pool.query(`
      select 
        count(*)::int as total,
        count(*) filter (where status = 'new')::int as new,
        count(*) filter (where status = 'in_progress')::int as in_progress,
        count(*) filter (where status = 'resolved')::int as resolved
      from public.support_inquiries
    `),
  ]);

  return res.json({
    stats: {
      retailers: retailersRes.rows[0],
      users: usersRes.rows[0],
      meters: {
        ...metersRes.rows[0],
        totalReadings: readingsRes.rows[0]?.total ?? 0,
      },
      support: supportRes.rows[0],
    },
  });
}));

// 2. GET /admin/retailers
router.get('/retailers', route(async (req, res) => {
  const q = req.query;
  const status = q.status && q.status !== 'all' ? q.status : null;
  const search = typeof q.search === 'string' && q.search.trim() ? `%${q.search.trim().toLowerCase()}%` : null;
  const limit = Math.min(200, Math.max(1, parseInt(q.limit || '50', 10) || 50));
  const offset = Math.max(0, parseInt(q.offset || '0', 10) || 0);

  const conditions = [];
  const params = [];

  if (status) {
    params.push(status);
    conditions.push(`r.status = $${params.length}`);
  }

  if (search) {
    params.push(search);
    conditions.push(`(
      lower(r.name) like $${params.length}
      or lower(r.address_line) like $${params.length}
      or lower(coalesce(r.state, '')) like $${params.length}
      or lower(coalesce(r.city_lga, '')) like $${params.length}
      or lower(coalesce(u.email, '')) like $${params.length}
      or lower(coalesce(u.username, '')) like $${params.length}
      or lower(coalesce(r.phone_e164, '')) like $${params.length}
    )`);
  }

  const whereClause = conditions.length > 0 ? `where ${conditions.join(' and ')}` : '';

  const countQuery = `
    select count(*)::int as total
    from public.retailers r
    left join public.users u on u.id = r.app_user_id
    ${whereClause}
  `;
  const countRes = await pool.query(countQuery, params);
  const total = countRes.rows[0]?.total || 0;

  params.push(limit);
  const limitIdx = params.length;
  params.push(offset);
  const offsetIdx = params.length;

  const dataQuery = `
    select 
      r.id, r.app_user_id, r.name, r.phone_e164, r.address_line, r.state, r.city_lga,
      r.latitude, r.longitude, r.is_available, r.opening_hours, r.price_per_kg,
      r.logo_url, r.about, r.status, r.status_reason, r.reviewed_by, r.reviewed_at,
      r.created_at, r.updated_at,
      u.email as owner_email, u.username as owner_username, u.phone as owner_phone
    from public.retailers r
    left join public.users u on u.id = r.app_user_id
    ${whereClause}
    order by 
      case when r.status = 'pending' then 1 else 2 end,
      r.created_at desc
    limit $${limitIdx} offset $${offsetIdx}
  `;
  const { rows } = await pool.query(dataQuery, params);

  return res.json({
    retailers: rows.map(formatRetailer),
    total,
    limit,
    offset,
  });
}));

// 3. GET /admin/retailers/:id
router.get('/retailers/:id', route(async (req, res) => {
  const id = v.uuid(req.params.id);
  const query = `
    select 
      r.id, r.app_user_id, r.name, r.phone_e164, r.address_line, r.state, r.city_lga,
      r.latitude, r.longitude, r.is_available, r.opening_hours, r.price_per_kg,
      r.logo_url, r.about, r.status, r.status_reason, r.reviewed_by, r.reviewed_at,
      r.created_at, r.updated_at,
      u.email as owner_email, u.username as owner_username, u.phone as owner_phone
    from public.retailers r
    left join public.users u on u.id = r.app_user_id
    where r.id = $1
  `;
  const { rows } = await pool.query(query, [id]);
  if (!rows[0]) return res.status(404).json({ error: 'Retailer not found' });
  return res.json({ retailer: formatRetailer(rows[0]) });
}));

// 4. PATCH /admin/retailers/:id
router.patch('/retailers/:id', route(async (req, res) => {
  const id = v.uuid(req.params.id);
  const b = req.body || {};

  const updates = [];
  const params = [];

  if (b.name !== undefined) {
    params.push(v.text(b.name, 'name', { min: 2, max: 120 }));
    updates.push(`name = $${params.length}`);
  }
  if (b.phone !== undefined) {
    params.push(v.phone(b.phone, 'phone'));
    updates.push(`phone_e164 = $${params.length}`);
  }
  if (b.address !== undefined) {
    params.push(v.text(b.address, 'address', { min: 4, max: 200 }));
    updates.push(`address_line = $${params.length}`);
  }
  if (b.state !== undefined) {
    params.push(v.text(b.state, 'state', { min: 2, max: 60, optional: true }));
    updates.push(`state = $${params.length}`);
  }
  if (b.cityLga !== undefined) {
    params.push(v.text(b.cityLga, 'cityLga', { min: 2, max: 60, optional: true }));
    updates.push(`city_lga = $${params.length}`);
  }
  if (b.latitude !== undefined) {
    params.push(v.num(b.latitude, 'latitude', { min: -90, max: 90, optional: true }));
    updates.push(`latitude = $${params.length}`);
  }
  if (b.longitude !== undefined) {
    params.push(v.num(b.longitude, 'longitude', { min: -180, max: 180, optional: true }));
    updates.push(`longitude = $${params.length}`);
  }
  if (b.pricePerKg !== undefined) {
    params.push(b.pricePerKg === null ? null : v.num(b.pricePerKg, 'pricePerKg', { min: 100, max: 50000 }));
    updates.push(`price_per_kg = $${params.length}`);
  }
  if (b.isAvailable !== undefined) {
    params.push(v.bool(b.isAvailable, 'isAvailable'));
    updates.push(`is_available = $${params.length}`);
  }
  if (b.openingHours !== undefined) {
    params.push(v.openingHours(b.openingHours));
    updates.push(`opening_hours = $${params.length}`);
  }
  if (b.about !== undefined) {
    params.push(v.text(b.about, 'about', { min: 1, max: 1000, optional: true }));
    updates.push(`about = $${params.length}`);
  }
  if (b.status !== undefined) {
    if (!['pending', 'approved', 'rejected'].includes(b.status)) {
      throw v.bad('status must be pending, approved, or rejected');
    }
    params.push(b.status);
    updates.push(`status = $${params.length}`);
    params.push(req.user.id);
    updates.push(`reviewed_by = $${params.length}`);
    updates.push(`reviewed_at = now()`);
  }
  if (b.statusReason !== undefined) {
    params.push(v.text(b.statusReason, 'statusReason', { min: 1, max: 300, optional: true }));
    updates.push(`status_reason = $${params.length}`);
  }

  if (updates.length === 0) {
    throw v.bad('No update fields provided');
  }

  updates.push('updated_at = now()');
  params.push(id);

  const updateQuery = `
    update public.retailers
    set ${updates.join(', ')}
    where id = $${params.length}
    returning *
  `;
  const { rows } = await pool.query(updateQuery, params);
  if (!rows[0]) return res.status(404).json({ error: 'Retailer not found' });

  // If approved, update owner's role to retailer
  if (b.status === 'approved' && rows[0].app_user_id) {
    try {
      await pool.query("update public.users set role = 'retailer' where id = $1 and role != 'admin'", [rows[0].app_user_id]);
    } catch (_) { /* non-fatal */ }
  }
  if (b.status === 'approved' || b.status === 'rejected') {
    notifyRetailerReview({
      userId: rows[0].app_user_id,
      stationName: rows[0].name,
      decision: b.status,
      reason: b.statusReason,
    });
  }

  return res.json({ retailer: formatRetailer(rows[0]) });
}));

// 5. DELETE /admin/retailers/:id
router.delete('/retailers/:id', route(async (req, res) => {
  const id = v.uuid(req.params.id);
  const { rowCount } = await pool.query('delete from public.retailers where id = $1', [id]);
  if (!rowCount) return res.status(404).json({ error: 'Retailer not found' });
  return res.json({ ok: true });
}));

// 6. GET /admin/users
router.get('/users', route(async (req, res) => {
  const q = req.query;
  const role = q.role && q.role !== 'all' ? q.role : null;
  const search = typeof q.search === 'string' && q.search.trim() ? `%${q.search.trim().toLowerCase()}%` : null;
  const limit = Math.min(200, Math.max(1, parseInt(q.limit || '50', 10) || 50));
  const offset = Math.max(0, parseInt(q.offset || '0', 10) || 0);

  const conditions = [];
  const params = [];

  if (role) {
    params.push(role);
    conditions.push(`u.role = $${params.length}`);
  }

  if (search) {
    params.push(search);
    conditions.push(`(
      lower(coalesce(u.email, '')) like $${params.length}
      or lower(coalesce(u.username, '')) like $${params.length}
      or lower(coalesce(u.phone, '')) like $${params.length}
    )`);
  }

  const whereClause = conditions.length > 0 ? `where ${conditions.join(' and ')}` : '';

  const countQuery = `select count(*)::int as total from public.users u ${whereClause}`;
  const countRes = await pool.query(countQuery, params);
  const total = countRes.rows[0]?.total || 0;

  params.push(limit);
  const limitIdx = params.length;
  params.push(offset);
  const offsetIdx = params.length;

  const dataQuery = `
    select 
      u.id, u.email, u.phone, u.username, u.role,
      u.phone_verified_at, u.email_verified_at, u.created_at,
      count(distinct r.id)::int as station_count,
      count(distinct m.id) filter (where m.deleted_at is null)::int as meter_count
    from public.users u
    left join public.retailers r on r.app_user_id = u.id
    left join public.meters m on m.owner_user_id = u.id
    ${whereClause}
    group by u.id
    order by u.created_at desc
    limit $${limitIdx} offset $${offsetIdx}
  `;
  const { rows } = await pool.query(dataQuery, params);

  return res.json({
    users: rows.map((u) => ({
      id: u.id,
      email: u.email,
      phone: u.phone,
      username: u.username,
      role: u.role,
      phoneVerified: Boolean(u.phone_verified_at),
      emailVerified: Boolean(u.email_verified_at),
      createdAt: u.created_at,
      stationCount: u.station_count,
      meterCount: u.meter_count,
    })),
    total,
    limit,
    offset,
  });
}));

// 7. PATCH /admin/users/:id/role
router.patch('/users/:id/role', route(async (req, res) => {
  const id = v.uuid(req.params.id);
  const { role } = req.body || {};
  if (!['consumer', 'retailer', 'admin'].includes(role)) {
    throw v.bad('role must be consumer, retailer, or admin');
  }

  if (id === req.user.id && role !== 'admin') {
    throw v.bad('Cannot demote your own admin account');
  }

  const { rows } = await pool.query(
    'update public.users set role = $1 where id = $2 returning id, email, username, phone, role',
    [role, id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'User not found' });
  return res.json({ user: rows[0] });
}));

// 8. GET /admin/meters
router.get('/meters', route(async (_req, res) => {
  const query = `
    select 
      m.id, m.owner_user_id, m.bt_address, m.label, m.cylinder_size_kg,
      m.created_at, m.updated_at, m.last_reading_at, m.deleted_at,
      u.email as owner_email, u.username as owner_username, u.phone as owner_phone,
      r.percent as last_percent, r.weight_kg as last_weight_kg,
      r.battery as last_battery, r.leak_level as last_leak_level,
      r.recorded_at as last_reading_recorded_at
    from public.meters m
    join public.users u on u.id = m.owner_user_id
    left join lateral (
      select percent, weight_kg, battery, leak_level, recorded_at
      from public.meter_readings mr
      where mr.meter_id = m.id
      order by mr.recorded_at desc
      limit 1
    ) r on true
    order by coalesce(m.last_reading_at, m.created_at) desc
    limit 200
  `;
  const { rows } = await pool.query(query);
  return res.json({
    meters: rows.map((m) => ({
      id: m.id,
      ownerUserId: m.owner_user_id,
      ownerEmail: m.owner_email,
      ownerUsername: m.owner_username,
      ownerPhone: m.owner_phone,
      btAddress: m.bt_address,
      label: m.label,
      cylinderSizeKg: m.cylinder_size_kg === null ? null : Number(m.cylinder_size_kg),
      createdAt: m.created_at,
      updatedAt: m.updated_at,
      lastReadingAt: m.last_reading_at,
      isDeleted: Boolean(m.deleted_at),
      latestReading: m.last_reading_recorded_at ? {
        percent: m.last_percent === null ? null : Number(m.last_percent),
        weightKg: m.last_weight_kg === null ? null : Number(m.last_weight_kg),
        battery: m.last_battery === null ? null : Number(m.last_battery),
        leakLevel: m.last_leak_level,
        recordedAt: m.last_reading_recorded_at,
      } : null,
    })),
  });
}));

// 9. GET /admin/support
router.get('/support', route(async (req, res) => {
  const q = req.query;
  const status = q.status && q.status !== 'all' ? q.status : null;
  const search = typeof q.search === 'string' && q.search.trim() ? `%${q.search.trim().toLowerCase()}%` : null;
  const limit = Math.min(200, Math.max(1, parseInt(q.limit || '50', 10) || 50));
  const offset = Math.max(0, parseInt(q.offset || '0', 10) || 0);

  const conditions = [];
  const params = [];

  if (status) {
    params.push(status);
    conditions.push(`s.status = $${params.length}`);
  }

  if (search) {
    params.push(search);
    conditions.push(`(
      lower(s.name) like $${params.length}
      or lower(coalesce(s.email, '')) like $${params.length}
      or lower(coalesce(s.phone, '')) like $${params.length}
      or lower(s.subject) like $${params.length}
      or lower(s.message) like $${params.length}
    )`);
  }

  const whereClause = conditions.length > 0 ? `where ${conditions.join(' and ')}` : '';

  const countQuery = `select count(*)::int as total from public.support_inquiries s ${whereClause}`;
  const countRes = await pool.query(countQuery, params);
  const total = countRes.rows[0]?.total || 0;

  params.push(limit);
  const limitIdx = params.length;
  params.push(offset);
  const offsetIdx = params.length;

  const dataQuery = `
    select 
      s.id, s.name, s.email, s.phone, s.subject, s.message, s.category,
      s.status, s.admin_notes, s.user_id, s.created_at, s.updated_at,
      u.email as user_email, u.username as user_username
    from public.support_inquiries s
    left join public.users u on u.id = s.user_id
    ${whereClause}
    order by 
      case when s.status = 'new' then 1 when s.status = 'in_progress' then 2 else 3 end,
      s.created_at desc
    limit $${limitIdx} offset $${offsetIdx}
  `;
  const { rows } = await pool.query(dataQuery, params);

  return res.json({
    inquiries: rows.map((s) => ({
      id: s.id,
      name: s.name,
      email: s.email,
      phone: s.phone,
      subject: s.subject,
      message: s.message,
      category: s.category,
      status: s.status,
      adminNotes: s.admin_notes,
      userId: s.user_id,
      userEmail: s.user_email,
      userUsername: s.user_username,
      createdAt: s.created_at,
      updatedAt: s.updated_at,
    })),
    total,
    limit,
    offset,
  });
}));

// 10. PATCH /admin/support/:id
router.patch('/support/:id', route(async (req, res) => {
  const id = v.uuid(req.params.id);
  const b = req.body || {};

  const updates = [];
  const params = [];

  if (b.status !== undefined) {
    if (!['new', 'in_progress', 'resolved'].includes(b.status)) {
      throw v.bad('status must be new, in_progress, or resolved');
    }
    params.push(b.status);
    updates.push(`status = $${params.length}`);
  }

  if (b.adminNotes !== undefined) {
    params.push(v.text(b.adminNotes, 'adminNotes', { min: 1, max: 2000, optional: true }));
    updates.push(`admin_notes = $${params.length}`);
  }

  if (updates.length === 0) {
    throw v.bad('No update fields provided');
  }

  updates.push('updated_at = now()');
  params.push(id);

  const query = `
    update public.support_inquiries
    set ${updates.join(', ')}
    where id = $${params.length}
    returning *
  `;
  const { rows } = await pool.query(query, params);
  if (!rows[0]) return res.status(404).json({ error: 'Inquiry not found' });

  return res.json({ inquiry: rows[0] });
}));

// GET /admin/diagnostics — hardware fleet health, recent device alerts/events, and audit logs
router.get('/diagnostics', route(async (_req, res) => {
  const [eventsRes, auditsRes, summaryRes] = await Promise.all([
    pool.query(
      `select de.id, de.meter_id, de.event_type, de.severity, de.message, de.payload, de.created_at,
              m.label as meter_label, m.bt_address, m.firmware_version, m.last_rssi,
              u.email as owner_email, u.username as owner_username
         from public.device_events de
         join public.meters m on m.id = de.meter_id
         left join public.users u on u.id = m.owner_user_id
        order by de.created_at desc
        limit 50`
    ),
    pool.query(
      `select al.id, al.actor_user_id, al.action, al.target_type, al.target_id, al.metadata, al.created_at,
              u.email as actor_email, u.username as actor_username
         from public.audit_logs al
         left join public.users u on u.id = al.actor_user_id
        order by al.created_at desc
        limit 50`
    ),
    pool.query(
      `select
         count(*) filter (where deleted_at is null)::int as total_meters,
         count(*) filter (where deleted_at is null and device_key_hash is not null)::int as provisioned_devices,
         count(*) filter (where deleted_at is null and last_reading_at >= now() - interval '24 hours')::int as active_24h,
         count(*) filter (where deleted_at is null and firmware_version is not null)::int as with_firmware
       from public.meters`
    ),
  ]);

  res.json({
    ok: true,
    summary: summaryRes.rows[0] || {
      total_meters: 0,
      provisioned_devices: 0,
      active_24h: 0,
      with_firmware: 0,
    },
    recentEvents: eventsRes.rows,
    recentAuditLogs: auditsRes.rows,
  });
}));

module.exports = router;
