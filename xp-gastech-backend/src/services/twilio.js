const twilio = require('twilio');

function getTwilioConfig() {
  const accountSid = process.env.TWILIO_ACCOUNT_SID;
  const authToken = process.env.TWILIO_AUTH_TOKEN;
  const from = process.env.TWILIO_PHONE_NUMBER;
  const configured = Boolean(accountSid && authToken && from);
  return { accountSid, authToken, from, configured };
}

async function sendSms(to, body) {
  const { accountSid, authToken, from, configured } = getTwilioConfig();
  if (!configured) {
    const err = new Error('Twilio is not configured. Set TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER.');
    err.code = 'TWILIO_NOT_CONFIGURED';
    throw err;
  }
  const client = twilio(accountSid, authToken);
  return client.messages.create({ to, from, body });
}

module.exports = { getTwilioConfig, sendSms };
