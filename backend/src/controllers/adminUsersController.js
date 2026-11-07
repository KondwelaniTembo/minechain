// Controllers translate HTTP into service calls and back. The rules (which status may
// change to which, the last-admin lock, the audit entries) all live in accountService.
//
// By the time any of these run, the router has checked the token, the admin role, and the
// request's params, query and body. Errors are not caught: Express 5 passes a rejected
// promise to errorHandler, which turns an AppError into its 403, 404 or 409.
export function createAdminUsersController({ accounts }) {
  // The acting admin comes from req.user, which requireAuth loaded from the database, never
  // from anything the client sent. req.ip is the client address as Express resolved it
  // with TRUST_PROXY, for the audit entry.
  const actor = (req) => ({ actorId: req.user.id, ipAddress: req.ip });
  const targetId = (req) => req.validated.params.id;

  return {
    async list(req, res) {
      res.status(200).json(await accounts.list(req.validated.query));
    },

    async approve(req, res) {
      const user = await accounts.approve({ targetId: targetId(req), ...actor(req) });
      res.status(200).json({ user });
    },

    async reject(req, res) {
      const user = await accounts.reject({ targetId: targetId(req), reason: req.validated.body.reason, ...actor(req) });
      res.status(200).json({ user });
    },

    async suspend(req, res) {
      const user = await accounts.suspend({ targetId: targetId(req), reason: req.validated.body.reason, ...actor(req) });
      res.status(200).json({ user });
    },

    async reactivate(req, res) {
      const user = await accounts.reactivate({ targetId: targetId(req), ...actor(req) });
      res.status(200).json({ user });
    },

    async resetKey(req, res) {
      const user = await accounts.resetKey({ targetId: targetId(req), reason: req.validated.body.reason, ...actor(req) });
      res.status(200).json({ user });
    },
  };
}
