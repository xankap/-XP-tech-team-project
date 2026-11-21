require('dotenv').config();
const { sendEmail, welcomeEmail, getEmailConfig } = require('../src/services/sendchampEmail');

async function main() {
  const target = process.argv[2];
  if (!target) {
    console.error('Usage: node scripts/test_email.js <recipient_email>');
    process.exit(1);
  }

  const cfg = getEmailConfig();
  console.log('Email configuration:', {
    configured: cfg.configured,
    provider: cfg.provider,
    from: `${cfg.fromName} <${cfg.fromEmail}>`,
  });

  if (!cfg.configured) {
    console.error('❌ Email is not configured. RESEND_API_KEY is missing from .env');
    process.exit(1);
  }

  console.log(`Sending branded welcome test email to ${target}...`);
  const msg = welcomeEmail({ email: target, name: 'XP Tester' });
  await sendEmail({
    to: target,
    name: 'XP Tester',
    subject: msg.subject,
    html: msg.html,
    text: msg.text,
  });

  console.log(`✅ Success! Email delivered to ${target} via ${cfg.provider}.`);
}

main().catch((err) => {
  console.error('❌ Failed to send email:', err && err.message, err && err.providerResponse);
  process.exit(1);
});
