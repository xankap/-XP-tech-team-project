// Shared route helpers.
function sendError(res, err, fallback, tag = 'api') {
  if (err.status) return res.status(err.status).json({ error: err.message || fallback });
  if (err.code === '23505') return res.status(409).json({ error: 'Already exists' });
  if (err.code === '23514' || err.code === '22P02') return res.status(400).json({ error: 'Invalid input' });
  console.error(`[${tag}] ${fallback}:`, err);
  return res.status(500).json({ error: fallback });
}

const asyncRoute = (fallback, tag) => (fn) => async (req, res) => {
  try {
    await fn(req, res);
  } catch (err) {
    sendError(res, err, fallback, tag);
  }
};

module.exports = { sendError, asyncRoute };
