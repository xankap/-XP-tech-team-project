// Vercel serverless entrypoint: re-export the Express app.
// server.js only calls app.listen() when run directly (`node server.js`),
// so importing it here is side-effect free (no port binding).
const { app } = require('../server');

module.exports = app;
