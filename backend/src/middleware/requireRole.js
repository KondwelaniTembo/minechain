import { AppError } from '../errors.js';
import { ROLES } from '../roles.js';

// Allows a request only if the logged-in user has one of the given roles. Must come after
// requireAuth on the route, for example:
//
//   router.get('/alerts', requireAuth, requireRole('officer'), controller.list)
//
// The role is read from req.user, which requireAuth loads from the database on every
// request. The token's own role claim is never used here.
//
// Refusals are not audited: like refused tokens, they could be repeated endlessly and would
// flood the append-only audit log (see docs/decisions.md).
export function requireRole(...roles) {
  // Checked when the route is built, so a typo such as 'officr' stops the server at
  // start-up instead of quietly refusing everyone.
  if (roles.length === 0) {
    throw new TypeError('requireRole needs at least one role');
  }
  for (const role of roles) {
    if (!ROLES.includes(role)) {
      throw new TypeError(`requireRole: unknown role ${JSON.stringify(role)}; expected one of ${ROLES.join(', ')}`);
    }
  }
  const allowed = new Set(roles);

  return function requireRoleMiddleware(req, res, next) {
    // Fail closed. No req.user means requireAuth is missing from this route: a programming
    // error, not something the client did. A plain Error becomes a logged 500, so the
    // request is refused and the mistake is loud, rather than hidden behind a normal 403.
    if (!req.user || typeof req.user.role !== 'string') {
      return next(new Error('requireRole ran without requireAuth before it on this route'));
    }

    // Generic on purpose: naming the allowed roles would tell a caller which account to go
    // after.
    if (!allowed.has(req.user.role)) {
      return next(new AppError(403, 'FORBIDDEN', 'You do not have permission to do this.'));
    }

    return next();
  };
}
