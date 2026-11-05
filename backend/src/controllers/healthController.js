export function createHealthController({ db }) {
  return {
    async check(req, res) {
      try {
        // The cheapest query that still proves the database accepts connections.
        await db.query('SELECT 1');
        res.status(200).json({ status: 'ok', database: 'up' });
      } catch (err) {
        // 503 rather than 500: the API itself works, a service it depends on does not.
        // Hosting platforms read this as "not ready" and can restart or hold traffic.
        // The reason is logged for the developer but not sent, since /health is public.
        console.error('Health check database query failed:', err.message);
        res.status(503).json({ status: 'error', database: 'down' });
      }
    },
  };
}
