const USERNAME_RE = /^[a-z0-9._]{3,20}$/;
const USERNAME_HINT = 'Username must be 3–20 characters: letters, numbers, underscores or periods.';

// Short, obvious names we never hand out (even if they match the format).
const RESERVED = new Set([
  'admin', 'administrator', 'support', 'help', 'official', 'system',
  'root', 'me', 'api', 'auth', 'null', 'undefined',
  'xptech', 'xptechltd', 'xp',
]);

function normalizeUsername(raw, { required = false } = {}) {
  if (raw === undefined || raw === null || (typeof raw === 'string' && raw.trim() === '')) {
    return required ? undefined : null;
  }
  if (typeof raw !== 'string') return undefined;
  const v = raw.trim().toLowerCase();
  if (!USERNAME_RE.test(v)) return undefined;
  return v;
}

function isReserved(username) {
  return typeof username === 'string' && RESERVED.has(username);
}

function invalidUsernameError(message = USERNAME_HINT) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

function takenUsernameError() {
  const err = new Error('Username already taken');
  err.status = 409;
  err.code = 'USERNAME_TAKEN';
  return err;
}

function uniqueViolationKind(err) {
  if (!err || err.code !== '23505') return null;
  const hay = `${err.constraint || ''} ${err.detail || ''} ${err.message || ''}`.toLowerCase();
  if (hay.includes('username')) return 'username';
  return 'other';
}

async function isUsernameTaken(pool, username, { exceptUserId } = {}) {
  const { rows } = exceptUserId
    ? await pool.query('select 1 from users where username = $1 and id <> $2 limit 1', [username, exceptUserId])
    : await pool.query('select 1 from users where username = $1 limit 1', [username]);
  return rows.length > 0;
}

module.exports = {
  USERNAME_RE,
  USERNAME_HINT,
  RESERVED,
  normalizeUsername,
  isReserved,
  invalidUsernameError,
  takenUsernameError,
  uniqueViolationKind,
  isUsernameTaken,
};
