const express = require('express');
const rateLimit = require('express-rate-limit');
const jwt = require('jsonwebtoken');
const { pool } = require('../db/pool');
const v = require('../validation');
const { asyncRoute } = require('./http');

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function tryGetUserId(req) {
  try {
    const header = req.headers.authorization || '';
    const match = header.match(/^Bearer\s+(.+)$/i);
    const secret = process.env.JWT_SECRET;
    if (!match || !secret) return null;
    const payload = jwt.verify(match[1], secret);
    if (!payload?.sub || (payload.typ && payload.typ !== 'access')) return null;
    return UUID_RE.test(payload.sub) ? payload.sub : null;
  } catch {
    return null;
  }
}

async function fetchUserDeviceDiagnostics(userId) {
  if (!userId) return [];
  try {
    const { rows } = await pool.query(
      `select m.id, m.label, m.bt_address, m.firmware_version, m.last_rssi, m.last_reading_at,
              r.percent as latest_percent, r.battery as latest_battery, r.leak_level as latest_leak,
              (
                select coalesce(json_agg(ev order by ev.created_at desc), '[]'::json)
                  from (
                    select event_type, severity, message, created_at
                      from public.device_events de
                     where de.meter_id = m.id
                     order by de.created_at desc
                     limit 5
                  ) ev
              ) as recent_events
         from public.meters m
         left join lateral (
           select percent, battery, leak_level
             from public.meter_readings mr
            where mr.meter_id = m.id
            order by mr.recorded_at desc
            limit 1
         ) r on true
        where m.owner_user_id = $1 and m.deleted_at is null
        order by m.updated_at desc
        limit 5`,
      [userId]
    );
    return rows;
  } catch (err) {
    console.warn('[assistant] device diagnostics query skipped:', err.message);
    return [];
  }
}

const router = express.Router();
const route = asyncRoute('Assistant request failed', 'assistant');

const chatLimiter = rateLimit({
  windowMs: 5 * 60 * 1000,
  max: 30,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many assistant messages. Please wait a moment.' },
});

const XP_GAS_SYSTEM_PROMPT = `You are "Pip", the friendly miniature AI assistant for XP GAS (XP Technologies Ltd, web app at https://xptechltd.com, admin portal at https://admin.xptechltd.com).
Answer user questions concisely, warmly, and accurately using ONLY verified XP GAS features and the live station snapshot below:

1. GAS METER CALIBRATION & MONITORING:
- Hardware: XP GAS Digital Gas Meter connects over Bluetooth (HC-05 module) or Wi-Fi/IoT direct telemetry to track live cylinder percentage, remaining kg, days left, battery level, and gas leak alerts.
- Calibration / Setup:
  1) Place the smart scale/meter on a flat, stable surface with nothing on it to zero (tare) the sensor.
  2) Select your exact cylinder size (e.g., 6kg, 12.5kg, 25kg, or 50kg) in Settings or during meter registration.
  3) Turn on Bluetooth, tap "Connect Meter" on the Dashboard, and pair with the HC-05 device.
  4) Readings sync offline on the phone and upload automatically when online.
- Leak Alert: If the leak sensor triggers, turn off the cylinder valve immediately, open windows, avoid flames/switches, and inspect the regulator hose.

2. SETTING UP A GAS PLANT / PARTNER STATION:
- How to register: On the Landing or Login page, click "Own a Gas Plant / Refill Station? Sign Up Here" (or click the store "+" icon on the Find Refill map).
- Required info: Plant name, facility type (LPG Refill Plant, Gas Skid, Cylinder Depot, Doorstep Delivery), international phone (+234...), physical address, State/LGA, live price per kg (₦/kg), Operating Hours (Opening & Closing Time + Sunday availability), and pinning the exact entrance coordinates on the interactive map.
- Verification: Submissions enter the XP GAS Admin verification queue at https://admin.xptechltd.com. Once approved by an admin, the account is upgraded to "retailer" and the plant goes live on the Find Refill map.

3. FINDING GAS REFILLS:
- Open the "Find Refill" tab to view nearby verified plants on the interactive map.
- Filter by "All Stations", "In Stock (Open)", or "Lowest Price".
- Each plant card shows live price per kg, operating hours, and calculated 6kg / 12.5kg / 25kg / 50kg refill estimates, plus one-tap Directions and Call buttons.

4. REACHING XP GAS ADMIN / SUPPORT:
- Users can message XP GAS Admin directly through this assistant's "Contact XP Admin" action (which submits a ticket to the Admin Support Desk at https://admin.xptechltd.com).

Keep replies short (2-5 sentences or crisp bullet points) and recommend the most relevant next step.`;

async function fetchLiveStationSummary() {
  try {
    const { rows } = await Promise.race([
      pool.query(`
        select name, state, city_lga, price_per_kg, is_available, opening_hours
        from public.retailers
        where status = 'approved'
        order by is_available desc, updated_at desc
        limit 10
      `),
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 1500)),
    ]);
    return rows || [];
  } catch (_) {
    return [];
  }
}

function formatHoursBrief(hours) {
  if (!hours || typeof hours !== 'object') return null;
  const sample = hours.mon || hours.tue || hours.sat;
  if (sample && sample.open && sample.close) {
    return `${sample.open}-${sample.close}`;
  }
  return null;
}

function recommendResources(text) {
  const q = text.toLowerCase();
  const resources = [];
  if (/(calibrat|meter|bluetooth|hc-05|leak|sensor|cylinder|tare)/.test(q)) {
    resources.push({ label: 'Meter Calibration Guide', action: 'calibration_guide' });
  }
  if (/(plant|station|retailer|register|pin|price|hours|open|close|verify)/.test(q)) {
    resources.push({ label: 'Gas Plant Partner Portal', action: 'station_portal' });
  }
  if (/(refill|map|nearby|buy gas|cheapest|find)/.test(q)) {
    resources.push({ label: 'Find Refill Map', action: 'find_refill' });
  }
  if (/(admin|support|help|ticket|contact|complain|issue|human)/.test(q)) {
    resources.push({ label: 'Send Ticket to XP Admin', action: 'support_form' });
  }
  if (resources.length === 0) {
    resources.push({ label: 'Send Ticket to XP Admin', action: 'support_form' });
  }
  return resources;
}

function localXpGasReply(message, liveStations = []) {
  const q = message.toLowerCase();
  if (/(pre-?order|order|buy.*meter|get.*meter|subscription|monthly|annual|plan)/.test(q)) {
    return 'You can register your Smart Gas Meter pre-order interest directly in the Pre-order section on this page! For existing devices, sign in via "My Account" to manage monthly or annual device telemetry subscriptions.';
  }
  if (/(farmer|agric|crop|irrigat|training|pcb|robot|education)/.test(q)) {
    return 'XP Technology builds the XP Farmers Assistant (IoT + AI crop monitoring & irrigation) and delivers practical Electronics, Robotics, AI, and PCB design training. Use the Support enquiry form to discuss a project or training programme.';
  }
  if (/(calibrat|tare|zero|scale|bluetooth|hc-05|meter|pair)/.test(q)) {
    return 'To calibrate your XP GAS digital meter:\n1. Place the meter scale on a flat surface with no cylinder on it so it zeroes cleanly.\n2. Set your cylinder size (6kg, 12.5kg, 25kg, or 50kg) in Settings.\n3. Enable Bluetooth and tap "Connect Meter" on your Dashboard to pair with your HC-05 unit.';
  }
  if (/(leak|smell|danger|alarm|safety)/.test(q)) {
    return 'If your XP GAS leak sensor triggers or you smell gas: immediately close the cylinder valve, open all doors and windows, avoid switches or flames, and check your regulator/hose connection before relighting.';
  }
  if (/(plant|station|retailer|register|business|pin|opening|closing|hours)/.test(q) && !/(find|near|cheapest|open now|which|list)/.test(q)) {
    return 'To set up your Gas Plant on XP GAS:\n1. Click "Own a Gas Plant / Refill Station? Sign Up Here" on the login screen (or the "+" store button on the Find Refill map).\n2. Enter your plant name, +234 phone, price per kg, Opening & Closing times, and pin your entrance on the map.\n3. XP GAS Admin will verify your coordinates at admin.xptechltd.com and publish your station.';
  }
  if (/(admin|support|ticket|contact|help|human|verify)/.test(q)) {
    return 'You can reach the XP GAS Admin team directly from here! Tap "Send Ticket to XP Admin" below to submit your question, and our team will view and respond to it in the Support Desk.';
  }
  if (/(refill|map|near|price|buy|find|cheapest|open|which|list)/.test(q)) {
    if (liveStations.length > 0) {
      const top = liveStations.slice(0, 3).map((s) => {
        const price = s.price_per_kg != null ? `₦${Number(s.price_per_kg).toLocaleString()}/kg` : 'price on request';
        const hrs = formatHoursBrief(s.opening_hours);
        const loc = s.state ? ` (${s.state})` : '';
        return `• ${s.name}${loc}: ${price}${hrs ? `, ${hrs}` : ''}`;
      }).join('\n');
      return `Here are verified XP GAS plants currently live:\n${top}\nOpen the "Find Refill" tab to view all ${liveStations.length} stations on the map and get directions.`;
    }
    return 'Open the "Find Refill" tab to see verified LPG plants near you, filter by "In Stock" or "Lowest Price", check each plant\'s opening/closing hours, and tap Directions or Call.';
  }
  return 'Hi! I\'m Pip, your XP GAS assistant. I can help you calibrate your digital gas meter, set up and pin your gas plant, find nearby refills, or send a message straight to XP GAS Admin. What would you like help with?';
}

async function callGemini(message, history = [], liveStations = [], deviceDiagnostics = []) {
  const apiKey = (process.env.GEMINI_API_KEY || '').trim();
  if (!apiKey) return null;

  const liveContext = liveStations.length > 0
    ? `\n\nLIVE VERIFIED GAS STATIONS (${liveStations.length}):\n` + liveStations.map((s) => {
      const price = s.price_per_kg != null ? `₦${s.price_per_kg}/kg` : 'price unset';
      const hrs = formatHoursBrief(s.opening_hours) || 'hours unset';
      return `- ${s.name} (${s.city_lga || ''}, ${s.state || ''}): ${price}, ${s.is_available ? 'In Stock' : 'Out of Stock'}, hours ${hrs}`;
    }).join('\n')
    : '';

  const deviceContext = deviceDiagnostics.length > 0
    ? `\n\nUSER'S CONNECTED GAS METERS & RECENT DIAGNOSTICS:\n` + deviceDiagnostics.map((m) => {
      const events = Array.isArray(m.recent_events) && m.recent_events.length > 0
        ? m.recent_events.map((e) => `[${e.severity}] ${e.event_type}: ${e.message || ''}`).join('; ')
        : 'no recent events';
      return `- ${m.label || m.bt_address} (fw ${m.firmware_version || 'unknown'}, rssi ${m.last_rssi ?? 'n/a'}): gas=${m.latest_percent ?? 'n/a'}%, battery=${m.latest_battery ?? 'n/a'}%, leak=${m.latest_leak ?? 0}, events: ${events}`;
    }).join('\n')
    : '';

  const contents = [];
  if (Array.isArray(history)) {
    for (const turn of history.slice(-8)) {
      if (!turn || typeof turn.text !== 'string') continue;
      contents.push({
        role: turn.role === 'model' ? 'model' : 'user',
        parts: [{ text: turn.text.slice(0, 1000) }],
      });
    }
  }
  contents.push({ role: 'user', parts: [{ text: message }] });

  const candidates = [
    process.env.GEMINI_MODEL && process.env.GEMINI_MODEL.trim(),
    'gemini-3-flash-preview',
    'gemini-3.1-flash-lite-preview',
    'gemini-flash-latest',
  ].filter((v, i, arr) => v && arr.indexOf(v) === i);

  for (const model of candidates) {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`;
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: XP_GAS_SYSTEM_PROMPT + liveContext + deviceContext }] },
        contents,
        generationConfig: {
          temperature: 0.4,
          maxOutputTokens: 350,
        },
      }),
    });

    if (!res.ok) {
      const errText = await res.text().catch(() => '');
      console.warn(`[assistant] Gemini (${model}) returned ${res.status}: ${errText.slice(0, 200)}`);
      continue;
    }

    const data = await res.json();
    const reply = data?.candidates?.[0]?.content?.parts?.[0]?.text;
    if (typeof reply === 'string' && reply.trim()) {
      return reply.trim();
    }
  }
  return null;
}

// POST /assistant/chat
router.post('/chat', chatLimiter, route(async (req, res) => {
  const message = v.text(req.body?.message, 'message', { min: 1, max: 1000 });
  const history = Array.isArray(req.body?.history) ? req.body.history : [];
  const userId = tryGetUserId(req);

  const [liveStations, deviceDiagnostics] = await Promise.all([
    fetchLiveStationSummary(),
    fetchUserDeviceDiagnostics(userId),
  ]);
  // Only authenticated users invoke the paid Gemini API; unauthenticated
  // landing-page visitors use the zero-cost local XP GAS knowledge base.
  const geminiReply = userId
    ? await callGemini(message, history, liveStations, deviceDiagnostics).catch(() => null)
    : null;
  const reply = geminiReply || localXpGasReply(message, liveStations);
  const provider = geminiReply ? 'gemini' : 'xp-knowledge-base';
  const resources = recommendResources(`${message} ${reply}`);

  return res.json({
    reply,
    provider,
    liveStationsCount: liveStations.length,
    diagnosticsCount: deviceDiagnostics.length,
    resources,
  });
}));

module.exports = router;
module.exports.localXpGasReply = localXpGasReply;
module.exports.recommendResources = recommendResources;
