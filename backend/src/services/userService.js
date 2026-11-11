import { randomBytes } from 'node:crypto';
import { AppError } from '../errors.js';
import { notActiveError } from './accountStatus.js';
import { SIGNING_ROLES } from '../roles.js';
import { createSignatureService, spkiFingerprint } from './signatureService.js';
import { SigningError } from './signingError.js';
import { normalise as normaliseCode, hash as hashCode, matches as codeMatches } from './activationCode.js';

// Wrong codes allowed against one activation code. The fifth wrong one erases it, and an
// administrator must issue a new one. With 60 random bits, 5 guesses give an attacker a
// chance of about 4 in 10^18.
export const ACTIVATION_MAX_ATTEMPTS = 5;

// The invited account with this username, and whether its code is still in time. The expiry
// is judged by the database's clock, the same clock that set it (accountService), so the app
// server's clock never matters. code_live is NULL when there is no code.
const ACTIVATION_STATE = `
  SELECT id, activation_code_hash,
         activation_expires_at > clock_timestamp() AS code_live
    FROM users
   WHERE lower(username) = lower($1) AND status = 'invited'`;

// One wrong code. Counting and erasing are one statement, so two wrong guesses at the same
// moment cannot both see "4 so far" and both escape the erase: the second waits for the
// first's row lock and then counts from 5. In SET every column means its value before this
// statement, so all three lines see the same old count. The WHERE names the code that was
// judged ($3): if an administrator issued a new code in the meantime, a guess at the old one
// counts against nothing.
const COUNT_WRONG_CODE = `
  UPDATE users
     SET activation_failed_attempts = activation_failed_attempts + 1,
         activation_code_hash = CASE WHEN activation_failed_attempts + 1 >= $2 THEN NULL ELSE activation_code_hash END,
         activation_expires_at = CASE WHEN activation_failed_attempts + 1 >= $2 THEN NULL ELSE activation_expires_at END
   WHERE id = $1 AND status = 'invited' AND activation_code_hash = $3
  RETURNING activation_code_hash IS NULL AS code_erased`;

// The right code. Every condition that made it right is checked again in the WHERE, so the
// check and the change are one step: a second activation with the same code, a reissue or
// the expiry arriving in between all make this match nothing. The password hash and the new
// status are set together, as users_password_only_when_invited requires. approved_by stays
// NULL: the user.create entry records which administrator made the account.
const ACTIVATE = `
  UPDATE users
     SET password_hash = $3,
         status = 'active',
         activation_code_hash = NULL,
         activation_expires_at = NULL,
         activation_failed_attempts = 0
   WHERE id = $1 AND status = 'invited' AND activation_code_hash = $2
     AND activation_expires_at > clock_timestamp()
  RETURNING id, username, full_name, licence_number, role, status, created_at, public_key`;

// Only this unique violation means "username taken". Any other one, such as the
// astronomically unlikely actor_ref clash, is a server problem and stays a 500.
const USERNAME_CONSTRAINT = 'users_username_lower_key';
// The unique index from the users-public-key-unique migration: this key is on another account.
const PUBLIC_KEY_CONSTRAINT = 'users_public_key_key';
const UNIQUE_VIOLATION = '23505';

// Column names stay snake_case in SQL; the API speaks camelCase. Only safe fields are
// selected in the first place, so password_hash and actor_ref can never leak from here.
// public_key is selected only to be turned into its fingerprint: the raw key is never
// returned. The app compares the fingerprint with its own Keystore key's to know whether to
// register (null), carry on (equal), or ask an administrator (different).
function toSafeUser(row) {
  return {
    id: row.id,
    username: row.username,
    fullName: row.full_name,
    licenceNumber: row.licence_number,
    role: row.role,
    status: row.status,
    createdAt: row.created_at,
    publicKeyFingerprint: row.public_key ? spkiFingerprint(row.public_key) : null,
  };
}

// Sets the key only if the account has none yet, and only for an active account in a
// signing role. The check and the change are one statement, so two registrations at the
// same moment cannot both succeed: the second waits for the first's row lock, re-checks
// public_key IS NULL, and matches nothing.
const REGISTER_PUBLIC_KEY = `
  UPDATE users
     SET public_key = $2
   WHERE id = $1 AND public_key IS NULL AND status = 'active' AND role = ANY ($3::text[])
  RETURNING id, username, full_name, licence_number, role, status, created_at, public_key`;

// Read only when the UPDATE matched nothing, to choose the answer. same_key is NULL when
// the account has no key, which counts as false.
const KEY_STATE = `
  SELECT id, username, full_name, licence_number, role, status, created_at, public_key,
         public_key = $2 AS same_key
    FROM users
   WHERE id = $1`;

// One builder for both "unknown username" and "wrong password", so the two can never drift
// apart. Any difference in status, code or wording would tell an attacker which usernames
// exist (user enumeration).
function invalidCredentials() {
  return new AppError(401, 'INVALID_CREDENTIALS', 'Username or password is incorrect.');
}

// One builder for every failed activation, for the same reason as invalidCredentials: an
// unknown username, an account that is not invited, a missing, expired or wrong code all get
// exactly this answer, so it reveals neither which usernames exist nor which are waiting.
function activationInvalid() {
  return new AppError(401, 'ACTIVATION_INVALID', 'This activation code is not valid. Ask an administrator for a new one.');
}

// The policy's codes and messages only: the password itself is never sent back. Shared by
// registration, activation and password change, so all refuse a weak password in exactly
// the same words. field names the request field the password came in.
function weakPassword(problems, field = 'password') {
  return new AppError(
    400,
    'WEAK_PASSWORD',
    'Choose a stronger password.',
    problems.map(({ code, message }) => ({ field, code, message })),
  );
}

// 400, not 401: the person is logged in, and a 401 would make the app throw away their
// session over a typing mistake.
function currentPasswordIncorrect() {
  return new AppError(400, 'CURRENT_PASSWORD_INCORRECT', 'Your current password is not correct.', [
    { field: 'currentPassword', message: 'is not correct' },
  ]);
}

// A password change ends every other session. The fresh token's iat becomes the cut-off, so
// the change and the cut-off are one statement. AND password_hash = $4: if the password was
// changed in the moment since it was checked, this matches nothing rather than overwriting
// a change the person did not see.
const CHANGE_PASSWORD = `
  UPDATE users
     SET password_hash = $2,
         tokens_valid_after = to_timestamp($3::bigint)
   WHERE id = $1 AND password_hash = $4
  RETURNING id, username, full_name, licence_number, role, status, created_at, public_key`;

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
//   signatures:     the signature service (parsePublicKey); defaults to the real one, which
//                   is pure, so tests that never register a key need not pass it
export function createUserService({ db, passwords, passwordPolicy, audit, tokens, signatures = createSignatureService() }) {
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

  // Failed activations are security events, kept for the same reasons and in the same way
  // as failed logins: own statement, top-level db, never inside a transaction that the
  // following throw would roll back. details holds a fixed reason word (and codeErased on the
  // wrong code that erased it), never the code or password that was typed.
  const recordFailedActivation = (reason, { userId = null, ipAddress, extra = {} }) =>
    audit.record(db, {
      action: 'user.activation_failed',
      actorId: userId,
      entityType: userId ? 'user' : null,
      entityId: userId,
      details: { reason, ...extra },
      ipAddress,
    });

  // Kept for the same reason as failed logins: a run of wrong current passwords on a
  // logged-in session is a stolen phone or token trying to take the account over.
  const recordFailedPasswordChange = (reason, { userId, ipAddress }) =>
    audit.record(db, {
      action: 'user.password_change_failed',
      actorId: userId,
      entityType: 'user',
      entityId: userId,
      details: { reason },
      ipAddress,
    });

  return {
    // input has already passed registerSchema. ipAddress comes from the request, for the
    // audit entry.
    async register(input, { ipAddress = null } = {}) {
      const problems = passwordPolicy(input.password, { username: input.username });
      if (problems.length > 0) throw weakPassword(problems);

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
             RETURNING id, username, full_name, licence_number, role, status, created_at, public_key`,
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
        `SELECT id, username, full_name, licence_number, role, status, created_at, public_key, password_hash
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

      // An invited account (FR-10) has no password yet: there is nothing to verify, and
      // passing NULL to Argon2 would throw. It is answered exactly like an unknown username:
      // the same Argon2 work and the same 401, so neither the time taken nor the answer tells
      // anyone that the username exists or is waiting for activation. Only the audit entry,
      // which no client sees, says why.
      if (user.password_hash === null) {
        await passwords.verifyDummy(password);
        await recordFailedLogin('account_invited', { userId: user.id, ipAddress });
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

    // Activates an invited officer or administrator account (FR-10) with the code an
    // administrator gave them and the password they choose now. Returns
    // { user, token, expiresIn }, exactly like a login, so the app goes straight in.
    // input has passed activateBodySchema: the username is trimmed, the code is any short
    // string (normaliseCode decides whether it can be a code), the password is untouched.
    async activate({ username, code, password, ipAddress = null }) {
      // The password first, before anything about the account or code is looked at. A weak
      // password is refused without using up one of the 5 guesses, and the answer is the
      // same whether or not the username exists, so it reveals nothing.
      const problems = passwordPolicy(password, { username });
      if (problems.length > 0) throw weakPassword(problems);

      const { rows } = await db.query(ACTIVATION_STATE, [username]);
      const account = rows[0];

      // Unknown, or not invited (already active, pending, and so on): one reason, because
      // either way there is no code here to try.
      if (!account) {
        await recordFailedActivation('unknown_username', { ipAddress });
        throw activationInvalid();
      }
      const fail = async (reason, extra) => {
        await recordFailedActivation(reason, { userId: account.id, ipAddress, extra });
        return activationInvalid();
      };

      // Erased after too many wrong codes. Not counted as a guess: there is nothing to guess.
      if (account.activation_code_hash === null) throw await fail('no_code');
      if (!account.code_live) throw await fail('expired');

      // A typed value that cannot be a code at all counts as a wrong guess too, so malformed
      // values are not a way round the 5-guess limit.
      const canonical = normaliseCode(code);
      if (canonical === null || !codeMatches(hashCode(canonical), account.activation_code_hash)) {
        const { rows: counted } = await db.query(COUNT_WRONG_CODE, [
          account.id,
          ACTIVATION_MAX_ATTEMPTS,
          account.activation_code_hash,
        ]);
        throw await fail('wrong_code', counted[0]?.code_erased ? { codeErased: true } : {});
      }

      // Hashed before the transaction opens, as at registration: Argon2 takes about 50 ms.
      const passwordHash = await passwords.hash(password);

      const user = await db.transaction(async (tx) => {
        const { rows: activated } = await tx.query(ACTIVATE, [account.id, account.activation_code_hash, passwordHash]);
        // Lost a race: the code was used, replaced or expired since it was checked above.
        // Nothing changed, so returning null (not throwing) just ends the transaction; the
        // failure is then recorded outside it, below, as every failed activation is.
        if (activated.length === 0) return null;
        // Same transaction: the account becomes active only together with this record.
        await audit.record(tx, {
          action: 'user.activate',
          actorId: account.id,
          entityType: 'user',
          entityId: account.id,
          details: {},
          ipAddress,
        });
        return activated[0];
      });
      if (!user) throw await fail('code_changed');

      const { token, expiresIn } = await tokens.sign({ userId: user.id, role: user.role });
      return { user: toSafeUser(user), token, expiresIn };
    },

    // Changes the logged-in user's password and ends every other session (FR-06). userId is
    // req.user.id, which requireAuth loaded from the database, never a value from the body.
    // Returns { user, token, expiresIn } like a login: the phone that made the change swaps
    // to the fresh token and stays logged in; every older token is refused from now on.
    async changePassword({ userId, currentPassword, newPassword, ipAddress = null }) {
      const { rows } = await db.query(
        `SELECT id, username, full_name, licence_number, role, status, created_at, public_key, password_hash
           FROM users
          WHERE id = $1`,
        [userId],
      );
      const account = rows[0];
      // requireAuth loaded this user a moment ago; gone now gets what requireAuth would say.
      if (!account) throw staleToken();

      // The new password's policy first, as at activation: a weak choice is refused without
      // the current password being tried, so it never adds to the failed attempts.
      const problems = passwordPolicy(newPassword, { username: account.username });
      if (problems.length > 0) throw weakPassword(problems, 'newPassword');

      if (!(await passwords.verify(account.password_hash, currentPassword))) {
        await recordFailedPasswordChange('wrong_current_password', { userId, ipAddress });
        throw currentPasswordIncorrect();
      }

      // Compared with Argon2 against the stored hash, not as text, because the NFKC form is
      // what counts: a password typed with different but equivalent characters is the same.
      if (await passwords.verify(account.password_hash, newPassword)) {
        throw new AppError(400, 'PASSWORD_UNCHANGED', 'Choose a password different from your current one.', [
          { field: 'newPassword', message: 'must be different from your current password' },
        ]);
      }

      // Both before the transaction: Argon2 takes about 50 ms. The token is signed first so
      // its iat can become the cut-off, which the token then passes by construction.
      const newHash = await passwords.hash(newPassword);
      const { token, expiresIn, issuedAt } = await tokens.sign({ userId: account.id, role: account.role });

      const user = await db.transaction(async (tx) => {
        const { rows: changed } = await tx.query(CHANGE_PASSWORD, [account.id, newHash, issuedAt, account.password_hash]);
        // The password changed in between: the current password just checked is no longer
        // current. Nothing was written, so the throw rolls back nothing.
        if (changed.length === 0) throw currentPasswordIncorrect();
        // Same transaction: the change and its record are saved together. No password or
        // hash in details, only the fact that other sessions ended.
        await audit.record(tx, {
          action: 'user.password_change',
          actorId: account.id,
          entityType: 'user',
          entityId: account.id,
          details: { sessionsEnded: true },
          ipAddress,
        });
        return changed[0];
      });

      return { user: toSafeUser(user), token, expiresIn };
    },

    // Called by requireAuth on every request, after the token's signature and expiry have
    // been checked. The token says who the user *was* when it was issued; this checks who
    // they are *now*, so a suspension or role change takes effect at once rather than when
    // the token expires. Returns the safe user, read fresh from the database.
    //
    // iat is the token's issue time in whole seconds. A token issued before the account's
    // tokens_valid_after (set by a password change) matches no row, so it gets exactly the
    // answer a deleted account gets: no new message tells anyone a password was changed.
    // The cut-off is the iat of the token the change itself issued, so that token passes
    // (equal is allowed) and only the server's clock is ever involved. NULL: no cut-off.
    // A missing iat is NULL in SQL and fails the comparison, so it is refused whenever
    // there is a cut-off.
    async getAuthenticatedUser(userId, tokenRole, iat) {
      // password_hash is not even selected: nothing on this path needs it.
      const { rows } = await db.query(
        `SELECT id, username, full_name, licence_number, role, status, created_at, public_key
           FROM users
          WHERE id = $1
            AND (tokens_valid_after IS NULL OR $2::bigint >= extract(epoch FROM tokens_valid_after))`,
        [userId, iat],
      );
      const user = rows[0];

      if (!user) throw staleToken();
      if (user.status !== 'active') throw notActiveError(user.status);
      if (user.role !== tokenRole) throw staleToken();

      return toSafeUser(user);
    },

    // Registers the device key of the logged-in user (signing-spec section 2). userId comes
    // from requireAuth, never from the request body. publicKey is the base64 text the app
    // sent. Returns the safe user, now with its publicKeyFingerprint.
    //   - first registration: saved, with a user.key_register audit entry;
    //   - the same key again: nothing written, same answer, because the phone may retry
    //     after the first response was lost on a bad network;
    //   - a different key: 409, because replacing a key needs an administrator.
    async registerPublicKey(userId, publicKey, { ipAddress = null } = {}) {
      // Validated before the transaction opens. The bytes stored are the key's canonical
      // export, which parsePublicKey has already proved equal to what was sent.
      let keyBytes;
      try {
        keyBytes = signatures.parsePublicKey(publicKey).export({ type: 'spki', format: 'der' });
      } catch (err) {
        if (err instanceof SigningError) {
          throw new AppError(
            400,
            'INVALID_PUBLIC_KEY',
            'The device key must be a P-256 public key in SPKI DER form, sent as standard base64.',
          );
        }
        throw err;
      }
      // The audit entry names the key by fingerprint: the log is append-only for ever, and
      // the fingerprint identifies the key exactly without copying it there.
      const keyFingerprint = spkiFingerprint(keyBytes);

      try {
        return await db.transaction(async (tx) => {
          const { rows } = await tx.query(REGISTER_PUBLIC_KEY, [userId, keyBytes, SIGNING_ROLES]);
          if (rows.length === 1) {
            await audit.record(tx, {
              action: 'user.key_register',
              actorId: userId,
              entityType: 'user',
              entityId: userId,
              details: { keyFingerprint },
              ipAddress,
            });
            return toSafeUser(rows[0]);
          }

          // Nothing was updated: read the row only to explain why.
          const { rows: current } = await tx.query(KEY_STATE, [userId, keyBytes]);
          const user = current[0];
          // requireAuth loaded this user a moment ago; if it is gone or changed, the
          // answers match what requireAuth itself would now give.
          if (!user) throw staleToken();
          if (user.status !== 'active') throw notActiveError(user.status);
          if (!SIGNING_ROLES.includes(user.role)) {
            // The route refuses these roles first; this keeps the rule for any other caller.
            throw new AppError(403, 'FORBIDDEN', 'You do not have permission to do this.');
          }
          if (user.same_key) return toSafeUser(user);
          if (user.public_key) {
            throw new AppError(
              409,
              'PUBLIC_KEY_ALREADY_REGISTERED',
              'This account already has a different device key. Ask an administrator to reset it.',
            );
          }
          // Active, a signing role, no key, yet the UPDATE matched nothing: the row changed
          // between the two statements. A plain error, so it is a logged 500, not a guess.
          throw new Error('The account changed while its key was being registered');
        });
      } catch (err) {
        // The index decides, not an earlier check, so two accounts registering the same key
        // at the same moment cannot both succeed. The failed UPDATE rolled the transaction
        // back, so nothing was written.
        if (err.code === UNIQUE_VIOLATION && err.constraint === PUBLIC_KEY_CONSTRAINT) {
          throw new AppError(409, 'PUBLIC_KEY_IN_USE', 'This device key is already registered to another account.');
        }
        throw err;
      }
    },
  };
}
