// HTTP in, service call, HTTP out. Every rule (the allow-list, the row lock, the refusal
// states, the audit entries) lives in anchorStatusService.
//
// By the time any of these run, the router has checked the token, the admin role, and the
// request's params, query and body. Errors are not caught: Express 5 passes a rejected
// promise to errorHandler, which turns an AppError into its 404 or 409.
export function createAdminAnchoringController({ anchoring }) {
  // The acting admin comes from req.user, which requireAuth loaded from the database, never
  // from anything the client sent. req.ip is the client address as Express resolved it with
  // TRUST_PROXY, for the audit entry. The same as for /admin/users and /admin/zones.
  const actor = (req) => ({ actorId: req.user.id, ipAddress: req.ip });

  return {
    async status(req, res) {
      res.status(200).json(await anchoring.status());
    },

    async run(req, res) {
      const summary = await anchoring.run(actor(req));
      res.status(200).json({ summary });
    },

    async retry(req, res) {
      const step = await anchoring.retry({ stepId: req.validated.params.id, reason: req.validated.body.reason, ...actor(req) });
      res.status(200).json({ step });
    },
  };
}
