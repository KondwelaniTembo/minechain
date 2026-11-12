-- Up Migration

-- Officer and admin accounts created by an administrator (FR-10), activated by the person
-- with a single-use code, and the cut-off that lets a password change end other sessions.
--
-- A created account starts as 'invited': it exists, but cannot log in until the person
-- activates it and chooses their own password, so nobody else ever knows that password.
-- Until then it has NO password hash at all, rather than a made-up one: NULL says honestly
-- "no password yet", and a login can never match it. The activation code is stored only as
-- its SHA-256 hash (32 bytes); the plain code is shown once to the administrator and never
-- stored. The code is random with 60 bits, short-lived and limited to 5 wrong attempts, so a
-- fast hash is enough here, unlike for a person's chosen password (Argon2id).
--
-- Every existing row has a password hash and one of the four old statuses, so none of the
-- new or changed CHECKs can fail on existing data.
ALTER TABLE users
  -- The four statuses (D1) plus 'invited'. An invited account is not active, so every
  -- existing action (approve, reject, suspend, reactivate, reset key) refuses it, and the
  -- last-admin rule, which counts active admins only, does not count it.
  DROP CONSTRAINT users_status_valid,
  ADD CONSTRAINT users_status_valid
    CHECK (status IN ('pending', 'active', 'suspended', 'rejected', 'invited')),

  ALTER COLUMN password_hash DROP NOT NULL,
  -- Still Argon2id or bcrypt whenever there is a hash; a plain password still fails here.
  -- NULL is allowed by this rule; the next rule says exactly when.
  DROP CONSTRAINT users_password_is_hash,
  ADD CONSTRAINT users_password_is_hash
    CHECK (password_hash IS NULL OR password_hash LIKE '$argon2id$%' OR password_hash LIKE '$2b$%'),
  -- Both directions in one rule: an invited account never has a hash, and every other
  -- account (pending, active, suspended, rejected) always has one. Activation must therefore
  -- set the hash and the status in the same UPDATE.
  ADD CONSTRAINT users_password_only_when_invited
    CHECK ((password_hash IS NULL) = (status = 'invited')),

  -- The SHA-256 of the current activation code; NULL when there is none (never issued,
  -- used, or erased after too many wrong attempts).
  ADD COLUMN activation_code_hash bytea,
  -- When that code stops working. Checked against clock_timestamp() when it is used.
  ADD COLUMN activation_expires_at timestamptz,
  -- Wrong codes tried against the current code. Reset when a new code is issued.
  ADD COLUMN activation_failed_attempts smallint NOT NULL DEFAULT 0,
  -- A token issued before this moment is refused (password change ends other sessions).
  -- NULL means no cut-off, which is every account until its first password change.
  ADD COLUMN tokens_valid_after timestamptz,

  -- A SHA-256 digest is always 32 bytes; any other length is a bug, not a code.
  ADD CONSTRAINT users_activation_code_32_bytes
    CHECK (activation_code_hash IS NULL OR octet_length(activation_code_hash) = 32),
  -- A code and its expiry are set together and cleared together, so there is never a code
  -- that never expires, or an expiry with nothing to expire.
  ADD CONSTRAINT users_activation_complete
    CHECK ((activation_code_hash IS NULL) = (activation_expires_at IS NULL)),
  -- A code exists only while the account is waiting to be activated: once it is active, a
  -- leftover code must be impossible, not merely unused. (An invited account may have no
  -- code, after its code was erased; the administrator then issues a new one.)
  ADD CONSTRAINT users_activation_only_when_invited
    CHECK (activation_code_hash IS NULL OR status = 'invited'),
  ADD CONSTRAINT users_activation_attempts_non_negative
    CHECK (activation_failed_attempts >= 0);

-- Down Migration

-- An invited account has no password hash and could satisfy neither the old NOT NULL nor
-- the old status list, so the rollback stops with a clear message instead of failing on a
-- constraint half-way. Activate those accounts first, or remove them if they have no history.
DO $$
DECLARE
  invited_count integer;
BEGIN
  SELECT count(*) INTO invited_count FROM users WHERE status = 'invited';
  IF invited_count > 0 THEN
    RAISE EXCEPTION 'Cannot roll back users-activation: % invited account(s) exist. An invited account has no password hash, which the old schema requires. Activate or remove them first.', invited_count;
  END IF;
END
$$;

-- New constraints first, by name, then the columns, then the original rules, exactly as the
-- users migration wrote them.
ALTER TABLE users
  DROP CONSTRAINT users_activation_attempts_non_negative,
  DROP CONSTRAINT users_activation_only_when_invited,
  DROP CONSTRAINT users_activation_complete,
  DROP CONSTRAINT users_activation_code_32_bytes,
  DROP COLUMN tokens_valid_after,
  DROP COLUMN activation_failed_attempts,
  DROP COLUMN activation_expires_at,
  DROP COLUMN activation_code_hash,
  DROP CONSTRAINT users_password_only_when_invited,
  DROP CONSTRAINT users_password_is_hash,
  ADD CONSTRAINT users_password_is_hash
    CHECK (password_hash LIKE '$argon2id$%' OR password_hash LIKE '$2b$%'),
  ALTER COLUMN password_hash SET NOT NULL,
  DROP CONSTRAINT users_status_valid,
  ADD CONSTRAINT users_status_valid
    CHECK (status IN ('pending', 'active', 'suspended', 'rejected'));
