// HTTP in, service call, HTTP out. Every rule (the lock order, the step status from all its
// alerts, the steps that cannot be cleared, the stage, the audit entries) lives in
// alertService.
//
// By the time any of these run, the router has checked the token, the officer role, and the
// request's params, query and body. Errors are not caught: Express 5 passes a rejected
// promise to errorHandler, which turns an AppError into its 403, 404 or 409.
export function createAlertsController({ alerts }) {
  // The deciding officer comes from req.user, which requireAuth loaded from the database,
  // never from anything the client sent. req.ip is the client address as Express resolved it
  // with TRUST_PROXY, for the audit entry. The same as for the admin routes.
  const decision = (req) => ({
    alertId: req.validated.params.id,
    notes: req.validated.body.notes,
    officerId: req.user.id,
    ipAddress: req.ip,
  });

  return {
    async list(req, res) {
      res.status(200).json(await alerts.list(req.validated.query));
    },

    async get(req, res) {
      const alert = await alerts.get(req.validated.params.id);
      res.status(200).json({ alert });
    },

    // { alert, step, consignment }: the closed alert, its step's status now, and whether the
    // consignment is still held, so the app can update its list without asking again.
    async review(req, res) {
      res.status(200).json(await alerts.review(decision(req)));
    },

    async dismiss(req, res) {
      res.status(200).json(await alerts.dismiss(decision(req)));
    },
  };
}
