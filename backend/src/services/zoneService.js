import { AppError } from '../errors.js';

// Licensed GPS zones, managed by administrators (FR-11). Sync reads the active ones to
// check where a registration was made (FR-08, Anomaly rules (3)).
//
// A zone's boundary and licence number are fixed once it is created (decisions.md, GPS
// zones): every transactions.zone_id must keep meaning the shape that was checked when the
// step arrived. A new shape is a new zone. So no statement in this file updates boundary or
// licence_number; a test reads the UPDATE statements below to keep it that way.
// Zones are never deleted either, because transactions.zone_id refers to them.

// The columns an administrator sees, written out once. A fixed constant placed into fixed
// statements, never anything from a request.
const ZONE_COLUMNS = 'id, name, licence_number, status, boundary, created_by, created_at, updated_at';

// Ordered by name ignoring letter case, so "alpha" does not sort after "Zulu". Names are
// unique ignoring case, so lower(name) alone is already a full order; id is only a tiebreak
// that never decides.
const LIST_ZONES = `
  SELECT ${ZONE_COLUMNS}
    FROM gps_zones
   WHERE status = $1
   ORDER BY lower(name), id
   LIMIT $2 OFFSET $3`;

const COUNT_ZONES = 'SELECT count(*)::int AS total FROM gps_zones WHERE status = $1';

// status takes its default ('active').
const INSERT_ZONE = `
  INSERT INTO gps_zones (name, licence_number, boundary, created_by)
  VALUES ($1, $2, $3, $4)
  RETURNING ${ZONE_COLUMNS}`;

// Rename reads before it writes: the audit entry must name the old name, and an UPDATE's
// RETURNING gives only the new one. FOR UPDATE holds the row until the transaction ends,
// so a second rename at the same moment waits and then sees this one's result.
const LOCK_ZONE = `SELECT ${ZONE_COLUMNS} FROM gps_zones WHERE id = $1 FOR UPDATE`;

const RENAME = `
  UPDATE gps_zones
     SET name = $2
   WHERE id = $1
  RETURNING ${ZONE_COLUMNS}`;

// Locks every active zone until the transaction ends, for the "last active zone" warning.
// Without it, two admins deactivating the last two zones at once would each still see the
// other's zone as active (it is not committed yet), and neither would be warned.
// ORDER BY id: two transactions take the locks in the same order, so they wait for each
// other instead of deadlocking. The same approach as LOCK_ACTIVE_ADMINS in accountService.
const LOCK_ACTIVE_ZONES = `
  SELECT id
    FROM gps_zones
   WHERE status = 'active'
   ORDER BY id
     FOR UPDATE`;

// Counted after the change, in a statement of its own. PostgreSQL's default isolation
// (READ COMMITTED) gives each statement a fresh view, so this sees everything committed
// before it, including a deactivation that this transaction had to wait for, plus this
// transaction's own change.
const COUNT_ACTIVE = "SELECT count(*)::int AS active FROM gps_zones WHERE status = 'active'";

// Each names the status it starts from in its WHERE, so the check and the change are one
// step: if the zone is not in that status, no row comes back.
const DEACTIVATE = `
  UPDATE gps_zones
     SET status = 'inactive'
   WHERE id = $1 AND status = 'active'
  RETURNING ${ZONE_COLUMNS}`;

const REACTIVATE = `
  UPDATE gps_zones
     SET status = 'active'
   WHERE id = $1 AND status = 'inactive'
  RETURNING ${ZONE_COLUMNS}`;

const SELECT_STATUS = 'SELECT status FROM gps_zones WHERE id = $1';

const UNIQUE_VIOLATION = '23505';
// The unique index on lower(name) from the gps_zones migration. It covers inactive zones
// too, so a name is never reused, even by a zone that replaced the old one.
const NAME_CONSTRAINT = 'gps_zones_name_lower_key';

// For the 409 message: "Only an active zone can be deactivated."
const ACTIONS = {
  deactivate: { from: 'active', to: 'inactive', verb: 'deactivated', audit: 'gps_zone.deactivate' },
  reactivate: { from: 'inactive', to: 'active', verb: 'reactivated', audit: 'gps_zone.reactivate' },
};

// The warning returned when a deactivation leaves no zone active. Allowed on purpose: a
// revoked licence must be able to go, and Anomaly rules (3) already says what happens next.
export const NO_ACTIVE_ZONES_WARNING = Object.freeze({
  code: 'NO_ACTIVE_ZONES',
  message:
    'No GPS zone is active now, so every new registration will be flagged as outside a licensed zone ' +
    'until a zone is created or reactivated.',
});

// snake_case columns to the API's camelCase. boundary comes back from jsonb already as an
// array of [lat, lng] pairs.
function toZone(row) {
  return {
    id: row.id,
    name: row.name,
    licenceNumber: row.licence_number,
    status: row.status,
    boundary: row.boundary,
    createdBy: row.created_by,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

// PostgreSQL compares uuids ignoring letter case; the audit entry should hold one spelling.
const normalizeId = (id) => id.toLowerCase();

function zoneNotFound() {
  return new AppError(404, 'ZONE_NOT_FOUND', 'No GPS zone has this id.');
}

function nameTaken() {
  return new AppError(
    409,
    'ZONE_NAME_TAKEN',
    'A GPS zone with this name already exists. Names are compared ignoring letter case and include ' +
      'inactive zones. Choose another name, or rename the other zone first.',
  );
}

// Runs fn in a transaction and turns a name clash into ZONE_NAME_TAKEN. The unique index
// decides, not an earlier SELECT: two admins choosing the same name at once could both pass
// a "does it exist?" check, but only one can pass the index. By the time the error arrives
// here the transaction has been rolled back, so nothing was written.
async function withNameCheck(db, fn) {
  try {
    return await db.transaction(fn);
  } catch (err) {
    if (err.code === UNIQUE_VIOLATION && err.constraint === NAME_CONSTRAINT) throw nameTaken();
    throw err;
  }
}

// Dependencies are passed in, so DB tests can give a failing audit service to prove the
// change and its entry are saved together.
//   db:    the app's db object
//   audit: the audit service (record)
export function createZoneService({ db, audit }) {
  // Called only when a status UPDATE matched no row, to explain why. Throwing inside the
  // transaction rolls it back, so a refused action leaves nothing behind.
  async function refusal(tx, id, action) {
    const { rows } = await tx.query(SELECT_STATUS, [id]);
    if (rows.length === 0) return zoneNotFound();
    const { from, verb } = ACTIONS[action];
    return new AppError(
      409,
      'INVALID_STATUS_TRANSITION',
      `Only an ${from} zone can be ${verb}. This zone is ${rows[0].status}.`,
    );
  }

  return {
    // input has already passed listZonesQuerySchema, so limit and offset are capped. Two
    // statements: total may be one out if a zone changes between them, which is harmless
    // for a page count.
    async list({ status, limit, offset }) {
      const { rows } = await db.query(LIST_ZONES, [status, limit, offset]);
      const { rows: countRows } = await db.query(COUNT_ZONES, [status]);
      return { zones: rows.map(toZone), total: countRows[0].total, limit, offset };
    },

    // input has already passed createZoneBodySchema: the name is trimmed and the boundary
    // passed every corner and shape rule. A new zone is active at once, so the next sync
    // call checks registrations against it (sync reads the zones on every call).
    create({ name, licenceNumber = null, boundary, actorId, ipAddress = null }) {
      return withNameCheck(db, async (tx) => {
        // JSON.stringify: pg would send an array as a PostgreSQL array, not as JSON.
        const { rows } = await tx.query(INSERT_ZONE, [name, licenceNumber, JSON.stringify(boundary), actorId]);
        const zone = toZone(rows[0]);
        // The boundary itself is not copied into the log: it is in the row and can never
        // change there, so the count is enough to describe it.
        await audit.record(tx, {
          action: 'gps_zone.create',
          actorId,
          entityType: 'gps_zone',
          entityId: zone.id,
          details: { name: zone.name, licenceNumber: zone.licenceNumber, cornerCount: boundary.length },
          ipAddress,
        });
        return zone;
      });
    },

    // Allowed for active and inactive zones: renaming an old zone frees its name for the
    // zone that replaces it. Past alert details keep the name they were raised with.
    rename({ zoneId, name, actorId, ipAddress = null }) {
      const id = normalizeId(zoneId);
      return withNameCheck(db, async (tx) => {
        const { rows } = await tx.query(LOCK_ZONE, [id]);
        if (rows.length === 0) throw zoneNotFound();
        const current = rows[0];

        // Exactly the same text: nothing to change, so nothing is written or audited. A
        // change of letter case only ("kasempa" to "Kasempa") is a real change and goes on.
        if (current.name === name) return toZone(current);

        const { rows: updated } = await tx.query(RENAME, [id, name]);
        await audit.record(tx, {
          action: 'gps_zone.rename',
          actorId,
          entityType: 'gps_zone',
          entityId: id,
          details: { from: current.name, to: name },
          ipAddress,
        });
        return toZone(updated[0]);
      });
    },

    // active -> inactive. Past steps keep their zone_id, and no check is run again: a
    // deactivation only affects registrations synced after it.
    // Returns { zone, warning }: warning is NO_ACTIVE_ZONES_WARNING when no active zone is
    // left, otherwise null.
    deactivate({ zoneId, reason, actorId, ipAddress = null }) {
      const id = normalizeId(zoneId);
      return db.transaction(async (tx) => {
        await tx.query(LOCK_ACTIVE_ZONES);

        const { rows } = await tx.query(DEACTIVATE, [id]);
        if (rows.length === 0) throw await refusal(tx, id, 'deactivate');

        const { rows: countRows } = await tx.query(COUNT_ACTIVE);
        const activeZonesLeft = countRows[0].active;

        const { from, to } = ACTIONS.deactivate;
        await audit.record(tx, {
          action: ACTIONS.deactivate.audit,
          actorId,
          entityType: 'gps_zone',
          entityId: id,
          // The reason is kept only here, in the append-only log: the zone row has no
          // column for it.
          details: { from, to, reason, activeZonesLeft },
          ipAddress,
        });
        return { zone: toZone(rows[0]), warning: activeZonesLeft === 0 ? NO_ACTIVE_ZONES_WARNING : null };
      });
    },

    // inactive -> active. It takes no lock on the other zones: adding an active zone can
    // never cause the "no zone left" case that the lock in deactivate guards.
    reactivate({ zoneId, actorId, ipAddress = null }) {
      const id = normalizeId(zoneId);
      return db.transaction(async (tx) => {
        const { rows } = await tx.query(REACTIVATE, [id]);
        if (rows.length === 0) throw await refusal(tx, id, 'reactivate');

        const { from, to } = ACTIONS.reactivate;
        await audit.record(tx, {
          action: ACTIONS.reactivate.audit,
          actorId,
          entityType: 'gps_zone',
          entityId: id,
          details: { from, to },
          ipAddress,
        });
        return toZone(rows[0]);
      });
    },
  };
}
