import { randomBytes } from 'node:crypto';
import { AppError } from '../errors.js';
import { notActiveError } from './accountStatus.js';

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

// One builder for both "unknown username" and "wrong password", so the two can never drift
// apart. Any difference in status, code or wording would tell an attacker which usernames
// exist (user enumeration).
function invalidCredentials() {
  return new AppError(401, 'INVALID_CREDENTIALS', 'Username or password is incorrect.');
}

// A token that no longer matches the database: the user is gone, or their role changed.
// 401, because logging in again is the fix (it issues a fresh token with the current role).
// Same code and message as any other refused token, so nothing extra is revealed.
function staleToken() {
  return new AppError(401, 'TOKEN_INVALID', 'Your session is not valid. Please log in again.');
}

// Dependencies are passed in, so unit tests can give fakes and DB tests the real ones.
//   passwords:      the Argon2id service (hash, verify, verifyDummy, needsRehash)
//   passwordPolicy: checkPasswordPolicy(password, { username }) -> list of problems
//   audit:          the audit service (record)
//   tokens:         the token service (sign)
export function createUserService({ db, passwords, passwordPolicy, audit, tokens }) {
  // Failed logins are written with the top-level db, as their own statement, and never
  // inside a db.transaction callback: the caller throws straight afterwards, and a throw
  // inside a transaction would roll the entry back. A record of failed attempts is exactly
  // what an officer needs when someone is guessing passwords, so it must always be kept.
  // details holds only a fixed reason word. The username that was typed is never stored,
  // because people sometimes type their password into the username field.
  const recordFailedLogin = (reason, { userId = null, ipAddress }) =>
    audit.record(db, {
      action: 'user.login_failed',
      actorId: userId,
      entityType: userId ? 'user' : null,
      entityId: userId,
      details: { reason },
      ipAddress,
    });

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

    // Returns { user, token, expiresIn } for an active user with the right password.
    // Every failure path costs about the same (one Argon2 verify, one audit insert), so
    // response time does not reveal whether the username exists.
    async authenticate(username, password, { ipAddress = null } = {}) {
      const { rows } = await db.query(
        `SELECT id, username, full_name, licence_number, role, status, created_at, password_hash
           FROM users
          WHERE lower(username) = lower($1)`,
        [username],
      );
      const user = rows[0];

      if (!user) {
        // Same Argon2 work as a real check, then the same answer as a wrong password.
        await passwords.verifyDummy(password);
        await recordFailedLogin('unknown_username', { ipAddress });
        throw invalidCredentials();
      }

      if (!(await passwords.verify(user.password_hash, password))) {
        await recordFailedLogin('wrong_password', { userId: user.id, ipAddress });
        throw invalidCredentials();
      }

      // Status is checked only now, after the password: a pending account with a wrong
      // password still got the generic 401 above. So only someone who knows the password
      // learns the account's status.
      if (user.status !== 'active') {
        await recordFailedLogin(`account_${user.status}`, { userId: user.id, ipAddress });
        throw notActiveError(user.status);
      }

      // Success: the optional rehash and the login entry are saved together.
      const rehashed = passwords.needsRehash(user.password_hash);
      const newHash = rehashed ? await passwords.hash(password) : null;
      await db.transaction(async (tx) => {
        if (rehashed) {
          // AND password_hash = $3: if the password was changed in the moment since it was
          // read, the newer hash is kept rather than overwritten with this one.
          await tx.query('UPDATE users SET password_hash = $1 WHERE id = $2 AND password_hash = $3', [
            newHash,
            user.id,
            user.password_hash,
          ]);
        }
        await audit.record(tx, {
          action: 'user.login',
          actorId: user.id,
          entityType: 'user',
          entityId: user.id,
          details: { rehashed },
          ipAddress,
        });
      });

      const { token, expiresIn } = await tokens.sign({ userId: user.id, role: user.role });
      return { user: toSafeUser(user), token, expiresIn };
    },

    // Called by requireAuth on every request, after the token's signature and expiry have
    // been checked. The token says who the user *was* when it was issued; this checks who
    // they are *now*, so a suspension or role change takes effect at once rather than when
    // the token expires. Returns the safe user, read fresh from the database.
    async getAuthenticatedUser(userId, tokenRole) {
      // password_hash is not even selected: nothing on this path needs it.
      const { rows } = await db.query(
        `SELECT id, username, full_name, licence_number, role, status, created_at
           FROM users
          WHERE id = $1`,
        [userId],
      );
      const user = rows[0];

      if (!user) throw staleToken();
      if (user.status !== 'active') throw notActiveError(user.status);
      if (user.role !== tokenRole) throw staleToken();

      return toSafeUser(user);
    },
  };
}
