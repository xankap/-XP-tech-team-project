const express = require('express');
const rateLimit = require('express-rate-limit');
const { sendSmsCode, verifySmsCode } = require('../services/smsAuth');
const { signup, login } = require('../services/emailAuth');
const { loginWithGoogleIdToken } = require('../services/googleAuth');
const { requireAuth } = require('../middleware/auth');

const router = express.Router();

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

router.post('/signup', authLimiter, async (req, res) => {
  try {
    const result = await signup({
      email: req.body?.email,
      password: req.body?.password,
      phone: req.body?.phone,
    });
    res.status(201).json(result);
  } catch (err) {
    res.status(err.status || 500).json({ error: err.message || 'Signup failed' });
  }
});

router.post('/login', authLimiter, async (req, res) => {
  try {
    const result = await login({
      email: req.body?.email,
      password: req.body?.password,
    });
    res.status(200).json(result);
  } catch (err) {
    res.status(err.status || 500).json({ error: err.message || 'Login failed' });
  }
});


router.post('/google', authLimiter, async (req, res) => {
  try {
    const result = await loginWithGoogleIdToken(req.body?.idToken);
    res.status(200).json(result);
  } catch (err) {
    res.status(err.status || 500).json({ error: err.message || 'Google login failed' });
  }
});

router.get('/me', requireAuth, async (req, res) => {
  res.status(200).json({ user: req.user });
});

router.post('/send-sms-code', smsSendLimiter, async (req, res) => {
  try {
    const result = await sendSmsCode(req.body?.phone);
    res.status(200).json(result);
  } catch (err) {
    const status = err.status || (err.code === 'TWILIO_NOT_CONFIGURED' ? 503 : 500);
    res.status(status).json({ error: err.message || 'Failed to send code' });
  }
});

router.post('/verify-sms-code', smsVerifyLimiter, async (req, res) => {
  try {
    const result = await verifySmsCode(req.body?.phone, req.body?.code);
    res.status(200).json(result);
  } catch (err) {
    res.status(err.status || 500).json({ error: err.message || 'Verification failed' });
  }
});

module.exports = router;
