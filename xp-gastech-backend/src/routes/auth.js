const express = require('express');
const rateLimit = require('express-rate-limit');
const { sendSmsCode, verifySmsCode } = require('../services/smsAuth');
const { signup, login, verifyEmailToken, resendVerification, checkUsernameAvailable, setUsername, requestPasswordReset, resetPassword } = require('../services/emailAuth');
const { getEmailConfig, esc, layout } = require('../services/sendchampEmail');
const { loginWithGoogleIdToken } = require('../services/googleAuth');
const jwt = require('jsonwebtoken');
const { requireAuth } = require('../middleware/auth');
const { refreshSession, revokeSession, revokeFamily } = require('../services/sessions');

const router = express.Router();

// Send a JSON error. Known (status-tagged) errors keep their message; unexpected
// 5xx errors get a generic message so DB/internal details never leak to clients.
function sendError(res, err, fallback, defaultStatus = 500) {
  const status = err.status || defaultStatus;
  if (!err.status) console.error(`[auth] ${fallback}:`, err);
  const message = err.status ? err.message || fallback : fallback;
  const body = { error: message };
  if (err.status && ['EMAIL_NOT_VERIFIED', 'INVALID_REFRESH_TOKEN', 'REFRESH_RACE', 'USERNAME_TAKEN'].includes(err.code)) body.code = err.code;
  res.status(status).json(body);
}

const smsSendLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 5,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many SMS requests. Try again later.' },
});

const smsVerifyLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many verification attempts. Try again later.' },
});

const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 30,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many auth requests. Try again later.' },
});

const verifyLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many verification attempts. Try again later.' },
});

const resendLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 5,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests. Try again later.' },
});

// Device context stored with a refresh-token session (both optional, truncated server-side).
function sessionCtx(req) {
  return { deviceLabel: req.body?.deviceLabel, userAgent: req.get('user-agent') };
}

const refreshLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 60,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests. Try again later.' },
});

function verifyPage(ok) {
  const { appBaseUrl } = getEmailConfig();
  const title = ok ? 'Email verified' : 'Link invalid or expired';
  const body = ok
    ? `<p style="font-size:15px;line-height:24px;color:#1b2430">Your email has been verified. You can now sign in to your XP Tech account.</p>`
    : `<p style="font-size:15px;line-height:24px;color:#1b2430">This verification link is invalid, already used, or expired. Open the app, sign in, and request a new verification email.</p>`;
  return layout(title, `${body}<p style="margin-top:24px"><a href="${esc(appBaseUrl)}" style="display:inline-block;background:#0053BA;color:#ffffff;font-weight:700;padding:12px 24px;border-radius:8px;text-decoration:none">Open XP Tech</a></p>`);
}

router.get('/verify-email', verifyLimiter, async (req, res) => {
  let ok = false;
  try {
    ok = (await verifyEmailToken(String(req.query.token || ''))).ok;
  } catch (err) {
    console.error('[auth] verify-email failed:', err);
    return res.status(500).type('html').send(verifyPage(false));
  }
  res.status(ok ? 200 : 400).set('Cache-Control', 'no-store').type('html').send(verifyPage(ok));
});

router.post('/verify-email', verifyLimiter, async (req, res) => {
  try {
    const { ok } = await verifyEmailToken(req.body?.token);
    if (!ok) return res.status(400).json({ error: 'Invalid or expired verification link' });
    res.status(200).json({ ok: true, message: 'Email verified' });
  } catch (err) {
    sendError(res, err, 'Verification failed');
  }
});

router.post('/resend-verification', resendLimiter, async (req, res) => {
  try {
    res.status(200).json(await resendVerification(req.body?.email));
  } catch (err) {
    sendError(res, err, 'Request failed');
  }
});

router.post('/signup', authLimiter, async (req, res) => {
  try {
    const result = await signup({
      email: req.body?.email,
      password: req.body?.password,
      phone: req.body?.phone,
      username: req.body?.username,
    });
    res.status(201).json(result);
  } catch (err) {
    sendError(res, err, 'Signup failed');
  }
});

router.post('/login', authLimiter, async (req, res) => {
  try {
    const result = await login({
      email: req.body?.email,
      username: req.body?.username,
      identifier: req.body?.identifier,
      password: req.body?.password,
    }, sessionCtx(req));
    res.status(200).json(result);
  } catch (err) {
    sendError(res, err, 'Login failed');
  }
});


router.get('/username-available', authLimiter, async (req, res) => {
  try {
    res.set('Cache-Control', 'no-store').status(200).json(await checkUsernameAvailable(req.query?.u));
  } catch (err) {
    sendError(res, err, 'Could not check username');
  }
});

router.patch('/me', requireAuth, async (req, res) => {
  try {
    const result = await setUsername(req.user.id, req.body?.username);
    res.set('Cache-Control', 'no-store').status(200).json(result);
  } catch (err) {
    sendError(res, err, 'Could not update username');
  }
});

router.post('/google', authLimiter, async (req, res) => {
  try {
    const result = await loginWithGoogleIdToken(req.body?.idToken, sessionCtx(req));
    res.status(200).json(result);
  } catch (err) {
    sendError(res, err, 'Google login failed');
  }
});

router.get('/me', requireAuth, async (req, res) => {
  res.set('Cache-Control', 'no-store').status(200).json({ user: req.user });
});

// Exchange a refresh token for a new access token + rotated refresh token.
router.post('/refresh', refreshLimiter, async (req, res) => {
  try {
    const result = await refreshSession(req.body?.refreshToken, sessionCtx(req));
    res.set('Cache-Control', 'no-store').status(200).json(result);
  } catch (err) {
    sendError(res, err, 'Refresh failed');
  }
});

// Revoke this device's login. Accepts the refresh token in the body and/or a
// Bearer access token (revokes its session). Always 200 so logout never blocks.
router.post('/logout', refreshLimiter, async (req, res) => {
  try {
    await revokeSession(req.body?.refreshToken);
    const header = req.headers.authorization || '';
    const m = header.match(/^Bearer\s+(.+)$/i);
    if (m && process.env.JWT_SECRET) {
      try {
        const payload = jwt.verify(m[1], process.env.JWT_SECRET);
        if (payload?.sid) await revokeFamily(payload.sid);
      } catch (_) { /* expired/invalid access token: refresh-token revoke above is enough */ }
    }
  } catch (err) {
    console.error('[auth] logout revoke failed:', err && err.code);
  }
  res.status(200).json({ ok: true });
});

router.post('/send-sms-code', smsSendLimiter, async (req, res) => {
  try {
    const result = await sendSmsCode(req.body?.phone);
    res.status(200).json(result);
  } catch (err) {
    if (err.code === 'SMS_NOT_CONFIGURED' && !err.status) err.status = 503;
    sendError(res, err, 'Failed to send code');
  }
});

router.post('/verify-sms-code', smsVerifyLimiter, async (req, res) => {
  try {
    const result = await verifySmsCode(req.body?.phone, req.body?.code, sessionCtx(req));
    res.status(200).json(result);
  } catch (err) {
    sendError(res, err, 'Verification failed');
  }
});

router.post('/forgot-password', resendLimiter, async (req, res) => {
  try {
    const result = await requestPasswordReset(req.body?.email);
    res.status(200).json(result);
  } catch (err) {
    sendError(res, err, 'Could not process password reset request');
  }
});

router.post('/reset-password', verifyLimiter, async (req, res) => {
  try {
    const result = await resetPassword({
      token: req.body?.token,
      newPassword: req.body?.newPassword || req.body?.password,
    });
    res.status(200).json(result);
  } catch (err) {
    sendError(res, err, 'Could not reset password');
  }
});

router.get('/reset-password', verifyLimiter, (req, res) => {
  const token = String(req.query?.token || '');
  const { appBaseUrl } = getEmailConfig();
  const body = `
    <p style="font-size:15px;line-height:24px;color:#1b2430">Enter a new password (8–72 characters) for your XP GAS account.</p>
    <form id="rf" style="margin-top:16px">
      <input type="hidden" id="tok" value="${esc(token)}">
      <input type="password" id="pwd" minlength="8" maxlength="72" required placeholder="New password" style="width:100%;box-sizing:border-box;padding:12px;border:1px solid #cbd5e1;border-radius:8px;font-size:15px;margin-bottom:12px">
      <button type="submit" style="width:100%;background:#0053BA;color:#fff;font-weight:700;padding:12px;border:none;border-radius:8px;font-size:15px;cursor:pointer">Update Password</button>
    </form>
    <p id="msg" style="margin-top:14px;font-size:14px"></p>
    <p style="margin-top:18px"><a href="${esc(appBaseUrl)}" style="color:#0053BA;font-weight:600;text-decoration:none">Back to XP GAS</a></p>
    <script>
      document.getElementById('rf').onsubmit = async function(e) {
        e.preventDefault();
        var msg = document.getElementById('msg');
        msg.textContent = 'Updating...';
        var r = await fetch('/auth/reset-password', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ token: document.getElementById('tok').value, newPassword: document.getElementById('pwd').value })
        });
        var d = await r.json();
        msg.style.color = r.ok ? '#10b981' : '#ef4444';
        msg.textContent = r.ok ? d.message : (d.error || 'Reset failed');
      };
    </script>`;
  res.status(200).set('Cache-Control', 'no-store').type('html').send(layout('Reset Password', body));
});

module.exports = router;
