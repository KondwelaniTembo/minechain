// A safety net, not the main protection: callers decide what goes into details, and must
// never pass secrets. This refuses the most likely mistakes, at any depth, before they are
// written to a table that can never be cleaned (audit_logs is append-only).
const SECRET_KEY = /password|token|secret/i;

function findSecretKey(value) {
  if (value === null || typeof value !== 'object') return null;
  for (const [key, inner] of Object.entries(value)) {
    if (SECRET_KEY.test(key)) return key;
    const nested = findSecretKey(inner);
    if (nested) return nested;
  }
  return null;
}

export function createAuditService() {
  return {
    // db is passed in rather than stored, so the entry joins whatever transaction the
    // caller is in. A new user and its user.register entry are then saved together, or
    // neither is.
    async record(db, { action, actorId = null, entityType = null, entityId = null, details = {}, ipAddress = null }) {
      const secretKey = findSecretKey(details);
      if (secretKey) {
        throw new TypeError(`Audit details must not contain "${secretKey}"`);
      }

      const { rows } = await db.query(
        `INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details, ip_address)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id, occurred_at`,
        // JSON.stringify: pg would send an array as a PostgreSQL array, not as JSON.
        [actorId, action, entityType, entityId, JSON.stringify(details), ipAddress],
      );
      // bigint id stays a string, so no precision is lost.
      return { id: rows[0].id, occurredAt: rows[0].occurred_at };
    },
  };
}
