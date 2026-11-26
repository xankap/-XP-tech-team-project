const crypto = require('crypto');

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Attaches industry-standard HTTP security headers and a unique X-Request-Id
 * for distributed tracing without leaking internal server details.
 */
function securityHeaders(req, res, next) {
  const incomingId = req.get('x-request-id');
  const requestId = incomingId && UUID_RE.test(incomingId.trim())
    ? incomingId.trim().toLowerCase()
    : crypto.randomUUID();

  req.requestId = requestId;
  res.setHeader('X-Request-Id', requestId);
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  res.setHeader('Permissions-Policy', 'geolocation=(), microphone=(), camera=()');

  if (req.secure || req.get('x-forwarded-proto') === 'https') {
    res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  }

  // Prevent caching of authenticated, admin, or hardware telemetry endpoints.
  if (/^\/(api\/v1\/)?(auth|admin|devices|meters|support)\b/i.test(req.path)) {
    res.setHeader('Cache-Control', 'no-store');
  }

  next();
}

/**
 * Lightweight structured logger for non-test environments.
 * Never logs Authorization headers, passwords, tokens, or X-Device-Key.
 */
function requestLogger(req, res, next) {
  if (process.env.NODE_ENV === 'test') return next();
  const start = Date.now();
  res.on('finish', () => {
    const durationMs = Date.now() - start;
    if (res.statusCode >= 500 || durationMs > 2500) {
      console.log(JSON.stringify({
        ts: new Date().toISOString(),
        requestId: req.requestId,
        method: req.method,
        path: req.path,
        status: res.statusCode,
        durationMs,
      }));
    }
  });
  next();
}

module.exports = { securityHeaders, requestLogger };
