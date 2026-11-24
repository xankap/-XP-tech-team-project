// Station logo storage on Supabase Storage. Dependency-free: plain fetch
// against the Storage REST API (POST object with x-upsert), so it also runs
// on Vercel serverless. One logo per station: retailer-logos/<userId>/logo.<ext>.
const v = require('../validation');

const BUCKET = 'retailer-logos';
// Decoded image bytes; base64 inflates ~4/3 on the wire, inside the 1mb
// JSON limit the server allows for the logo route.
const MAX_BYTES = 512 * 1024;
const TYPES = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };

function getConfig() {
  const url = (process.env.SUPABASE_URL || '').replace(/\/+$/, '');
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY || '';
  if (!url || !key) return null;
  return { url, key };
}

function isConfigured() {
  return getConfig() !== null;
}

function objectPath(userId, ext) {
  return `${userId}/logo.${ext}`;
}

function publicUrl(supabaseUrl, path) {
  return `${supabaseUrl.replace(/\/+$/, '')}/storage/v1/object/public/${BUCKET}/${path}`;
}

function magicOk(bytes, contentType) {
  if (contentType === 'image/jpeg') {
    return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  }
  if (contentType === 'image/png') {
    return bytes.length >= 8
      && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47
      && bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a;
  }
  if (contentType === 'image/webp') {
    return bytes.length >= 12
      && bytes.toString('ascii', 0, 4) === 'RIFF'
      && bytes.toString('ascii', 8, 12) === 'WEBP';
  }
  return false;
}

// Validates a JSON logo upload body. Accepts a raw base64 string or a
// data-URL (data:image/png;base64,...). Throws a 400-tagged Error.
function parseLogoUpload(body) {
  const b = body || {};
  const contentType = typeof b.contentType === 'string' ? b.contentType.trim().toLowerCase() : '';
  const ext = TYPES[contentType];
  if (!ext) throw v.bad('contentType must be one of image/jpeg, image/png, image/webp');
  let b64 = b.imageBase64;
  if (typeof b64 !== 'string' || !b64.trim()) throw v.bad('imageBase64 is required');
  b64 = b64.trim();
  const dataUrl = b64.match(/^data:([a-z]+\/[a-z0-9.+-]+);base64,/i);
  if (dataUrl) b64 = b64.slice(dataUrl[0].length);
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(b64)) throw v.bad('imageBase64 must be valid base64');
  let bytes;
  try {
    bytes = Buffer.from(b64, 'base64');
  } catch (_) {
    throw v.bad('imageBase64 must be valid base64');
  }
  if (!bytes.length) throw v.bad('imageBase64 must not be empty');
  if (bytes.length > MAX_BYTES) throw v.bad(`logo must be ${MAX_BYTES / 1024}KB or smaller`);
  if (!magicOk(bytes, contentType)) throw v.bad('image bytes do not match contentType');
  return { bytes, contentType, ext };
}

async function storageFetch(cfg, method, path, body, contentType) {
  const res = await fetch(`${cfg.url}/storage/v1/object/${BUCKET}/${path}`, {
    method,
    headers: {
      apikey: cfg.key,
      Authorization: `Bearer ${cfg.key}`,
      ...(contentType ? { 'Content-Type': contentType } : {}),
      ...(method === 'POST' ? { 'x-upsert': 'true' } : {}),
    },
    body,
  });
  return res;
}

function notConfigured() {
  const err = new Error('Logo uploads are not set up yet. The station owner needs to configure storage first.');
  err.status = 503;
  return err;
}

// Uploads (upsert) the station logo and returns its public URL. Old variants
// with a different extension are removed best-effort so only one logo exists.
async function uploadLogo({ userId, bytes, contentType, ext }) {
  const cfg = getConfig();
  if (!cfg) throw notConfigured();
  const path = objectPath(userId, ext);
  let res;
  try {
    res = await storageFetch(cfg, 'POST', path, bytes, contentType);
  } catch (_) {
    const err = new Error('Logo upload failed. Check your connection and try again.');
    err.status = 502;
    throw err;
  }
  if (!res.ok) {
    const err = new Error('Logo upload failed. Try again later.');
    err.status = 502;
    throw err;
  }
  for (const other of Object.values(TYPES)) {
    if (other === ext) continue;
    try {
      await storageFetch(cfg, 'DELETE', objectPath(userId, other));
    } catch (_) { /* best-effort cleanup */ }
  }
  return { path, url: publicUrl(cfg.url, path) };
}

// Removes every logo variant for the station. Best-effort: never throws.
async function deleteLogo(userId) {
  const cfg = getConfig();
  if (!cfg) return;
  for (const ext of Object.values(TYPES)) {
    try {
      await storageFetch(cfg, 'DELETE', objectPath(userId, ext));
    } catch (_) { /* ignore */ }
  }
}

module.exports = {
  BUCKET, MAX_BYTES, TYPES,
  isConfigured, getConfig, objectPath, publicUrl, parseLogoUpload,
  uploadLogo, deleteLogo,
};
