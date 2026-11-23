// HTTP in, service call, HTTP out. Every rule (which time counts, which steps, the weights)
// lives in dashboardService. By the time this runs, the router has checked the token, the
// officer role and the query.
export function createDashboardController({ dashboard }) {
  return {
    async summary(req, res) {
      res.status(200).json(await dashboard.summary(req.validated.query, req.user));
    },
  };
}
