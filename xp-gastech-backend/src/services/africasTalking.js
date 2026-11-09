const SMS_ENDPOINT = 'https://api.africastalking.com/version1/messaging';

function getAfricasTalkingConfig() {
  const username = process.env.AFRICASTALKING_USERNAME;
  const apiKey = process.env.AFRICASTALKING_API_KEY;
  const senderId = process.env.AFRICASTALKING_SENDER_ID;
  const configured = Boolean(username && apiKey);
  return { username, apiKey, senderId, configured };
}

async function sendSms(to, body) {
  const { username, apiKey, senderId, configured } = getAfricasTalkingConfig();
  if (!configured) {
    const err = new Error('Africa\'s Talking is not configured. Set AFRICASTALKING_USERNAME and AFRICASTALKING_API_KEY.');
    err.code = 'AFRICASTALKING_NOT_CONFIGURED';
    throw err;
  }

  const form = new URLSearchParams({ username, to, message: body });
  if (senderId) form.set('from', senderId);

  const response = await fetch(SMS_ENDPOINT, {
    method: 'POST',
    headers: {
      apiKey,
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json',
    },
    body: form,
  });
  const responseText = await response.text();
  let payload;
  try {
    payload = JSON.parse(responseText);
  } catch (_) {
    payload = { raw: responseText };
  }

  if (!response.ok) {
    const err = new Error('Africa\'s Talking rejected the SMS request.');
    err.code = 'AFRICASTALKING_SMS_FAILED';
    err.status = 502;
    err.providerResponse = payload;
    throw err;
  }

  const recipient = payload?.SMSMessageData?.Recipients?.[0];
  if (recipient && Number(recipient.statusCode) >= 400) {
    const err = new Error('Africa\'s Talking could not send the SMS.');
    err.code = 'AFRICASTALKING_SMS_FAILED';
    err.status = 502;
    err.providerResponse = payload;
    throw err;
  }
  return payload;
}

module.exports = { getAfricasTalkingConfig, sendSms };
