// Registered after every route, so Express only reaches it when nothing else matched.
// Without it, Express replies with an HTML page, and the app expects JSON everywhere.
export function notFound(req, res) {
  res.status(404).json({ error: { code: 'NOT_FOUND', message: 'Route not found' } });
}
