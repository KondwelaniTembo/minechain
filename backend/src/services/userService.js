import { randomBytes } from 'node:crypto';
import { AppError } from '../errors.js';

// Only this unique violation means "username taken". Any other one, such as the
// astronomically unlikely actor_ref clash, is a server problem and stays a 500.
const USERNAME_CONSTRAINT = 'users_username_lower_key';
const UNIQUE_VIOLATION = '23505';

// Column names stay snake_case in SQL; the API speaks camelCase. Only safe fields are
// selected in the first place, so password_hash and actor_ref can never leak from here.
function toSafeUser(row) {
  return {
    id: row.id,
    username: row.username,
    fullName: row.full_name,
    licenceNumber: row.licence_number,
    role: row.role,
    status: row.status,
    createdAt: row.created_at,
  };
}

// Dependencies are passed in, so unit tests can give fakes and DB tests the real ones.
//   passwords:      the Argon2id service (hash)
//   passwordPolicy: checkPasswordPolicy(password, { username }) -> list of problems
//   audit:          the audit service (record)
export function createUserService({ db, passwords, passwordPolicy, audit }) {
  return {
    // input has already passed registerSchema. ipAddress comes from the request, for the
    // audit entry.
    async register(input, { ipAddress = null } = {}) {
      const problems = passwordPolicy(input.password, { username: input.username });
      if (problems.length > 0) {
        // The policy's codes and messages only: the password itself is never sent back.
        throw new AppError(
          400,
          'WEAK_PASSWORD',
          'Choose a stronger password.',
          problems.map(({ code, message }) => ({ field: 'password', code, message })),
        );
      }

      // Hashed before the transaction opens: Argon2 takes about 50 ms, and keeping that
      // outside keeps the transaction, and anything it locks, as short as possible.
      const passwordHash = await passwords.hash(input.password);

      try {
        return await db.transaction(async (tx) => {
          // status is written into the SQL, not taken from input, so a new account is
          // always pending until an administrator approves it. actor_ref is random, never
          // derived from personal data, because it is the user's on-chain identity.
          const { rows } = await tx.query(
            `INSERT INTO users (username, full_name, licence_number, password_hash, role, status, actor_ref)
             VALUES ($1, $2, $3, $4, $5, 'pending', $6)
             RETURNING id, username, full_name, licence_number, role, status, created_at`,
            [input.username, input.fullName, input.licenceNumber ?? null, passwordHash, input.role, randomBytes(32)],
          );
          const user = rows[0];

          // Same transaction: the account and its audit entry are saved together, or
          // neither is. Only the role goes in details, never the password or its hash.
          await audit.record(tx, {
            action: 'user.register',
            actorId: user.id,
            entityType: 'user',
            entityId: user.id,
            details: { role: user.role },
            ipAddress,
          });

          return toSafeUser(user);
        });
      } catch (err) {
        // The unique index decides, not an earlier SELECT: two registrations arriving at
        // the same moment could both pass a "does it exist?" check, but only one can pass
        // the index. The comparison ignores case, because the index is on lower(username).
        if (err.code === UNIQUE_VIOLATION && err.constraint === USERNAME_CONSTRAINT) {
          throw new AppError(409, 'USERNAME_TAKEN', 'That username is already taken. Please choose another.');
        }
        throw err;
      }
    },
  };
}
