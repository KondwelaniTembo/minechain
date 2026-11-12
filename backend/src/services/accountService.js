import { randomBytes } from 'node:crypto';
import { AppError } from '../errors.js';
import { SELF_REGISTER_ROLES } from '../schemas/auth.js';
import { CREATABLE_ROLES } from '../schemas/adminUsers.js';
import { spkiFingerprint } from './signatureService.js';
import { generate as generateCode, hash as hashCode } from './activationCode.js';
import { withArticle } from './wording.js';

// How long an activation code works. Long enough for an administrator to hand it over in
// person or by phone and for the officer to find a signal, short enough that a code written
// on paper does not stay useful for long. The time is worked out in SQL from
// clock_timestamp(), so it never depends on the app server's clock.
export const ACTIVATION_TTL_HOURS = 72;

// The columns an administrator may see, written out once. A fixed constant placed into
// fixed statements, never anything from a request, so no input can become SQL. It leaves
// out password_hash, actor_ref (the on-chain identity) and activation_code_hash on purpose.
// public_key is selected only so toAdminUser can show its fingerprint; the raw key is never
// returned. activation_expires_at is safe to show: it is a time, not a secret.
const ADMIN_COLUMNS = `id, username, full_name, licence_number, role, status, status_reason,
                       approved_by, approved_at, created_at, updated_at, public_key,
                       activation_expires_at`;

const LIST_USERS = `
  SELECT ${ADMIN_COLUMNS}
    FROM users
   WHERE status = $1
   ORDER BY created_at, id
   LIMIT $2 OFFSET $3`;

const COUNT_USERS = 'SELECT count(*)::int AS total FROM users WHERE status = $1';

// One fixed statement per action. Each names the status it starts from in its WHERE, so
// the check and the change are one step: if two admins act at the same moment, the second
// UPDATE waits for the first's row lock, then re-checks the WHERE, matches nothing and
// returns no row. Only one of them can win.
//
// Approve and reject also require a self-registered role ($3), so a pending officer or
// admin (which the API never creates) can never be granted access with one click.
const APPROVE = `
  UPDATE users
     SET status = 'active', approved_by = $2, approved_at = now()
   WHERE id = $1 AND status = 'pending' AND role = ANY ($3::text[])
  RETURNING ${ADMIN_COLUMNS}`;

const REJECT = `
  UPDATE users
     SET status = 'rejected', status_reason = $2
   WHERE id = $1 AND status = 'pending' AND role = ANY ($3::text[])
  RETURNING ${ADMIN_COLUMNS}`;

const SUSPEND = `
  UPDATE users
     SET status = 'suspended', status_reason = $2
   WHERE id = $1 AND status = 'active'
  RETURNING ${ADMIN_COLUMNS}`;

// status_reason is cleared: it described the suspension, which is over. The database
// would allow keeping it, but an active account showing an old reason would mislead. The
// reason stays in the user.suspend audit entry. approved_by and approved_at are left
// alone: they record the first approval, a historical fact.
const REACTIVATE = `
  UPDATE users
     SET status = 'active', status_reason = NULL
   WHERE id = $1 AND status = 'suspended'
  RETURNING ${ADMIN_COLUMNS}`;

// Locks every active admin row until the transaction ends. ORDER BY id: two transactions
// always take the locks in the same order, so they wait for each other instead of
// deadlocking. A transaction that had to wait re-reads each row once it may continue, so
// an admin suspended a moment ago is no longer in the result.
const LOCK_ACTIVE_ADMINS = `
  SELECT id
    FROM users
   WHERE role = 'admin' AND status = 'active'
   ORDER BY id
     FOR UPDATE`;

const SELECT_STATE = 'SELECT role, status FROM users WHERE id = $1';

// A new officer or administrator account, waiting for its owner to activate it. status and
// the empty password hash are written into the SQL, not taken from input, so this statement
// can only ever create an invited account. approved_by stays NULL: nobody approved a request,
// and the user.create audit entry records who created the account. actor_ref is random, as
// at registration, because it is the user's on-chain identity.
const INSERT_INVITED = `
  INSERT INTO users (username, full_name, role, status, password_hash, actor_ref,
                     activation_code_hash, activation_expires_at)
  VALUES ($1, $2, $3, 'invited', NULL, $4, $5, clock_timestamp() + make_interval(hours => $6::int))
  RETURNING ${ADMIN_COLUMNS}`;

// A new code for an invited account. The old hash is overwritten, so the old code stops
// working at once; the attempt counter starts again. The status in the WHERE makes the check
// and the change one step, as for the other actions.
const REISSUE_ACTIVATION = `
  UPDATE users
     SET activation_code_hash = $2,
         activation_expires_at = clock_timestamp() + make_interval(hours => $3::int),
         activation_failed_attempts = 0
   WHERE id = $1 AND status = 'invited'
  RETURNING ${ADMIN_COLUMNS}`;

const UNIQUE_VIOLATION = '23505';
const USERNAME_CONSTRAINT = 'users_username_lower_key';

// Key reset reads before it writes, unlike the four actions above: the audit entry must name
// the key being removed, and an UPDATE's RETURNING gives only the new value (NULL). FOR UPDATE
// locks the row until the transaction ends, so nothing can change status or key between this
// read and the UPDATE: a lock-then-change, not an unguarded read-then-change.
const LOCK_KEY_STATE = 'SELECT status, public_key FROM users WHERE id = $1 FOR UPDATE';

const RESET_KEY = `
  UPDATE users
     SET public_key = NULL
   WHERE id = $1
  RETURNING ${ADMIN_COLUMNS}`;

// For the 409 message: "Only a pending account can be approved.", "Only an active account
// can be suspended."
const ACTIONS = {
  approve: { from: 'pending', to: 'active', verb: 'approved', audit: 'user.approve' },
  reject: { from: 'pending', to: 'rejected', verb: 'rejected', audit: 'user.reject' },
  suspend: { from: 'active', to: 'suspended', verb: 'suspended', audit: 'user.suspend' },
  reactivate: { from: 'suspended', to: 'active', verb: 'reactivated', audit: 'user.reactivate' },
};

// Column names stay snake_case in SQL; the API speaks camelCase. Unlike toSafeUser in
// userService, this includes statusReason and the approval fields: they are for admins.
function toAdminUser(row) {
  return {
    id: row.id,
    username: row.username,
    fullName: row.full_name,
    licenceNumber: row.licence_number,
    role: row.role,
    status: row.status,
    statusReason: row.status_reason,
    approvedBy: row.approved_by,
    approvedAt: row.approved_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    // Lets an administrator see whether the account has a device key before resetting it,
    // and compare it with the fingerprint the user's phone shows.
    publicKeyFingerprint: row.public_key ? spkiFingerprint(row.public_key) : null,
    // When the current activation code stops working, for an invited account that has one;
    // null otherwise (the database allows a code only while the account is invited). A time
    // in the past means the code has expired and a new one is needed.
    activationExpiresAt: row.activation_expires_at,
  };
}

// PostgreSQL compares uuids ignoring letter case, but JavaScript compares strings exactly.
// Without this, an admin could send their own id in capitals: the self-suspend check
// (a string comparison) would miss it, while the UPDATE would still find the row.
const normalizeId = (id) => id.toLowerCase();

// zoneService can write "an" into its template because both of its starting statuses
// begin with a vowel; account actions start from pending, active or suspended, so the
// article follows the word (withArticle, wording.js).

function userNotFound() {
  return new AppError(404, 'USER_NOT_FOUND', 'No user has this id.');
}

// Dependencies are passed in, so DB tests can give a failing audit service to prove the
// change and its entry are saved together.
//   db:    the app's db object
//   audit: the audit service (record)
export function createAccountService({ db, audit }) {
  // Called only when the UPDATE matched no row: the decision is already made, and this
  // only reads the row to explain it. Throwing inside the transaction rolls it back, so a
  // refused action leaves nothing behind.
  async function refusal(tx, id, action, { approvalOnly }) {
    const { rows } = await tx.query(SELECT_STATE, [id]);
    const user = rows[0];
    if (!user) return userNotFound();

    const { from, verb } = ACTIONS[action];
    // Role first: an officer or admin can never be approved or rejected here, whatever
    // their status, so the admin is told the real reason rather than a status.
    if (approvalOnly && !SELF_REGISTER_ROLES.includes(user.role)) {
      return new AppError(
        409,
        'ROLE_NOT_APPROVABLE',
        'Officer and administrator accounts are created by an administrator, not approved or rejected.',
      );
    }
    return new AppError(
      409,
      'INVALID_STATUS_TRANSITION',
      `Only ${withArticle(from)} account can be ${verb}. This account is ${user.status}.`,
    );
  }

  // Runs one action's statement and writes its audit entry in the same transaction, so the
  // change and the record of who made it are saved together or not at all.
  async function apply(tx, { action, sql, params, id, actorId, reason, ipAddress, approvalOnly = false }) {
    const { rows } = await tx.query(sql, params);
    if (rows.length === 0) {
      throw await refusal(tx, id, action, { approvalOnly });
    }

    const { from, to } = ACTIONS[action];
    await audit.record(tx, {
      action: ACTIONS[action].audit,
      actorId,
      entityType: 'user',
      entityId: id,
      // The reason is copied into the append-only log, where it can never be changed or
      // removed, so it is the full history even after reactivate clears status_reason.
      details: reason === undefined ? { from, to } : { from, to, reason },
      ipAddress,
    });
    return toAdminUser(rows[0]);
  }

  return {
    // input has already passed listUsersQuerySchema, so limit and offset are capped.
    // Two statements: total may be one out if an account changes between them, which is
    // harmless for a page count.
    async list({ status, limit, offset }) {
      const { rows } = await db.query(LIST_USERS, [status, limit, offset]);
      const { rows: countRows } = await db.query(COUNT_USERS, [status]);
      return { users: rows.map(toAdminUser), total: countRows[0].total, limit, offset };
    },

    // pending -> active (FR-12). Self-approval cannot happen: a pending admin cannot log
    // in, and users_no_self_approval would refuse it anyway.
    approve({ targetId, actorId, ipAddress = null }) {
      const id = normalizeId(targetId);
      return db.transaction((tx) =>
        apply(tx, {
          action: 'approve',
          sql: APPROVE,
          params: [id, actorId, SELF_REGISTER_ROLES],
          id,
          actorId,
          ipAddress,
          approvalOnly: true,
        }),
      );
    },

    // pending -> rejected (FR-12). Final: no action leads out of rejected (a known limit;
    // the person must register again under another username).
    reject({ targetId, actorId, reason, ipAddress = null }) {
      const id = normalizeId(targetId);
      return db.transaction((tx) =>
        apply(tx, {
          action: 'reject',
          sql: REJECT,
          params: [id, reason, SELF_REGISTER_ROLES],
          id,
          actorId,
          reason,
          ipAddress,
          approvalOnly: true,
        }),
      );
    },

    // active -> suspended (FR-10), for any role, with two extra rules for admins.
    async suspend({ targetId, actorId, reason, ipAddress = null }) {
      const id = normalizeId(targetId);
      // Checked before any SQL. 403: this is never allowed, whatever the account's state.
      if (id === normalizeId(actorId)) {
        throw new AppError(403, 'CANNOT_SUSPEND_SELF', 'You cannot suspend your own account.');
      }

      return db.transaction(async (tx) => {
        // The self rule alone seems to guarantee another admin remains, but two admins
        // suspending each other at the same moment would both pass it and leave none.
        // With the active admins locked, the second one waits, re-reads, and sees that the
        // first has already been suspended.
        const { rows } = await tx.query(LOCK_ACTIVE_ADMINS);
        const activeAdmins = new Set(rows.map((row) => row.id));
        // The acting admin must still be active too: if they were suspended a moment ago,
        // they no longer count as the admin who remains.
        if (activeAdmins.has(id) && (!activeAdmins.has(normalizeId(actorId)) || activeAdmins.size < 2)) {
          throw new AppError(
            409,
            'LAST_ACTIVE_ADMIN',
            'At least one other active administrator must remain, so this account cannot be suspended.',
          );
        }

        return apply(tx, { action: 'suspend', sql: SUSPEND, params: [id, reason], id, actorId, reason, ipAddress });
      });
    },

    // Removes a suspended account's device key, for a lost or replaced phone
    // (signing-spec section 2: suspend, reset, reactivate, register the new key). The status
    // does not change. Old steps keep verifying, because each stored step keeps a copy of
    // the key that signed it (D5).
    //
    // Only while suspended: on an active account, whoever logged in first afterwards would
    // register the next key, possibly the person holding the lost phone. The admin
    // reactivates only once the real user is confirmed.
    resetKey({ targetId, actorId, reason, ipAddress = null }) {
      const id = normalizeId(targetId);
      return db.transaction(async (tx) => {
        const { rows } = await tx.query(LOCK_KEY_STATE, [id]);
        const user = rows[0];
        if (!user) throw userNotFound();
        if (user.status !== 'suspended') {
          throw new AppError(
            409,
            'INVALID_STATUS_TRANSITION',
            `Only a suspended account can have its device key reset. This account is ${user.status}.`,
          );
        }
        if (!user.public_key) {
          // Refused rather than answered with a silent 200: an admin action with a reason
          // that did nothing would suggest a key had been removed.
          throw new AppError(409, 'NO_PUBLIC_KEY', 'This account has no device key to reset.');
        }

        // Named by fingerprint: the append-only log never holds the key itself.
        const keyFingerprint = spkiFingerprint(user.public_key);
        const { rows: updated } = await tx.query(RESET_KEY, [id]);
        await audit.record(tx, {
          action: 'user.key_reset',
          actorId,
          entityType: 'user',
          entityId: id,
          details: { reason, keyFingerprint },
          ipAddress,
        });
        return toAdminUser(updated[0]);
      });
    },

    // Creates an officer or administrator account (FR-10), invited until its owner activates
    // it with the code. input has already passed createUserBodySchema; the role is checked
    // again here, so no caller can create a miner, transporter or buyer this way. Any active
    // administrator may create another administrator (a known limitation; it is audited).
    //
    // Returns { user, activation: { code, expiresAt } }. This is the ONLY place the code
    // ever appears: only its hash is stored, and the audit entry never holds it.
    async createAccount({ username, fullName, role, actorId, ipAddress = null }) {
      if (!CREATABLE_ROLES.includes(role)) {
        throw new AppError(
          400,
          'ROLE_NOT_CREATABLE',
          'Only officer and administrator accounts are created by an administrator. Miners, transporters and buyers register themselves.',
        );
      }

      const { code, display } = generateCode();
      try {
        return await db.transaction(async (tx) => {
          const { rows } = await tx.query(INSERT_INVITED, [
            username,
            fullName,
            role,
            randomBytes(32),
            hashCode(code),
            ACTIVATION_TTL_HOURS,
          ]);
          const user = toAdminUser(rows[0]);
          await audit.record(tx, {
            action: 'user.create',
            actorId,
            entityType: 'user',
            entityId: user.id,
            // source tells these apart from the seed's user.create entries.
            details: { source: 'admin', role, activationExpiresAt: user.activationExpiresAt },
            ipAddress,
          });
          return { user, activation: { code: display, expiresAt: user.activationExpiresAt } };
        });
      } catch (err) {
        // The unique index decides, as at registration, so two admins choosing the same
        // username at once cannot both succeed. It covers every account in any letter case,
        // including invited, pending and rejected ones.
        if (err.code === UNIQUE_VIOLATION && err.constraint === USERNAME_CONSTRAINT) {
          throw new AppError(409, 'USERNAME_TAKEN', 'That username is already taken. Please choose another.');
        }
        throw err;
      }
    },

    // A new activation code for an invited account: the code was lost, it expired, or it
    // was erased after too many wrong attempts. The old code stops working at once, so this
    // is also how a mistaken invitation is revoked: reissue, and do not pass the new code
    // on. Returns { user, activation: { code, expiresAt } }, the only place the new code
    // appears.
    reissueActivation({ userId, actorId, ipAddress = null }) {
      const id = normalizeId(userId);
      const { code, display } = generateCode();
      return db.transaction(async (tx) => {
        const { rows } = await tx.query(REISSUE_ACTIVATION, [id, hashCode(code), ACTIVATION_TTL_HOURS]);
        if (rows.length === 0) {
          const { rows: found } = await tx.query(SELECT_STATE, [id]);
          if (found.length === 0) throw userNotFound();
          throw new AppError(
            409,
            'INVALID_STATUS_TRANSITION',
            `Only an invited account can get a new activation code. This account is ${found[0].status}.`,
          );
        }

        const user = toAdminUser(rows[0]);
        await audit.record(tx, {
          action: 'user.activation_reissue',
          actorId,
          entityType: 'user',
          entityId: id,
          details: { activationExpiresAt: user.activationExpiresAt },
          ipAddress,
        });
        return { user, activation: { code: display, expiresAt: user.activationExpiresAt } };
      });
    },

    // suspended -> active (FR-10).
    reactivate({ targetId, actorId, ipAddress = null }) {
      const id = normalizeId(targetId);
      return db.transaction((tx) =>
        apply(tx, { action: 'reactivate', sql: REACTIVATE, params: [id], id, actorId, ipAddress }),
      );
    },
  };
}
