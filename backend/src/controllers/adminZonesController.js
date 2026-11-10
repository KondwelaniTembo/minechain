// Controllers translate HTTP into service calls and back. The rules (fixed boundaries, name
// uniqueness, the last-zone warning, the audit entries) all live in zoneService.
//
// By the time any of these run, the router has checked the token, the admin role, and the
// request's params, query and body. Errors are not caught: Express 5 passes a rejected
// promise to errorHandler, which turns an AppError into its 404 or 409.
export function createAdminZonesController({ zones }) {
  // The acting admin comes from req.user, which requireAuth loaded from the database, never
  // from anything the client sent. req.ip is the client address as Express resolved it
  // with TRUST_PROXY, for the audit entry. The same as for /admin/users.
  const actor = (req) => ({ actorId: req.user.id, ipAddress: req.ip });
  const zoneId = (req) => req.validated.params.id;

  return {
    async list(req, res) {
      res.status(200).json(await zones.list(req.validated.query));
    },

    // 201: a new zone was made. The body is exactly what createZoneBodySchema let through
    // (name, boundary, and licenceNumber when one was sent).
    async create(req, res) {
      const zone = await zones.create({ ...req.validated.body, ...actor(req) });
      res.status(201).json({ zone });
    },

    async rename(req, res) {
      const zone = await zones.rename({ zoneId: zoneId(req), name: req.validated.body.name, ...actor(req) });
      res.status(200).json({ zone });
    },

    // warning is null, or NO_ACTIVE_ZONES when this was the last active zone. It is part of
    // a 200, not an error: the zone was deactivated, and the admin's app shows the warning.
    async deactivate(req, res) {
      const { zone, warning } = await zones.deactivate({ zoneId: zoneId(req), reason: req.validated.body.reason, ...actor(req) });
      res.status(200).json({ zone, warning });
    },

    async reactivate(req, res) {
      const zone = await zones.reactivate({ zoneId: zoneId(req), ...actor(req) });
      res.status(200).json({ zone });
    },
  };
}
