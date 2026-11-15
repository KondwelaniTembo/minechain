-- Up Migration

-- Soft delete of accounts by an administrator (B3). A deleted account keeps its row, so every
-- step, alert, approval and audit entry that names it keeps its meaning, and an anchored
-- step's actor_ref still points at someone. Only its ability to sign in is taken away.
--
-- A deleted account has NO password hash, as an invited one has none: NULL says "no
-- password", and no login can ever match it, so login answers exactly as for an unknown
-- username. The services treat 'deleted' as final, like 'rejected'; the rules below make sure
-- that a status change alone can never give a deleted account a way to sign in again.
--
-- No existing row is deleted, so each replaced rule gives the same answer as before for
-- every row already in the table, and none of these CHECKs can fail on existing data.
ALTER TABLE users
  -- The five statuses plus 'deleted'. A deleted account is not active, so every existing
  -- action refuses it, and the last-admin rule, which counts active admins only, does not
  -- count it.
  DROP CONSTRAINT users_status_valid,
  ADD CONSTRAINT users_status_valid
    CHECK (status IN ('pending', 'active', 'suspended', 'rejected', 'invited', 'deleted')),

  -- Deleting needs a reason, as suspending and rejecting do, so the record says why.
  DROP CONSTRAINT users_status_reason_required,
  ADD CONSTRAINT users_status_reason_required
    CHECK (status NOT IN ('suspended', 'rejected', 'deleted')
           OR (status_reason IS NOT NULL AND btrim(status_reason) <> '')),

  -- Both directions in one rule, as before: invited and deleted accounts never have a hash,
  -- and every other account always has one. A new name, because the old one
  -- (users_password_only_when_invited) would now describe the rule wrongly. Deleting must
  -- therefore erase the hash and set the status in the same UPDATE, and no UPDATE can bring
  -- a deleted account back to life by changing its status alone.
  DROP CONSTRAINT users_password_only_when_invited,
  ADD CONSTRAINT users_password_null_when_invited_or_deleted
    CHECK ((password_hash IS NULL) = (status IN ('invited', 'deleted'))),

  -- A deleted account's device key is revoked, so it can never sign a step again. The
  -- delete clears the key in its UPDATE; this rule makes a leftover key impossible, not
  -- merely unused, and stops a key being registered on a deleted account later.
  ADD CONSTRAINT users_deleted_has_no_public_key
    CHECK (status <> 'deleted' OR public_key IS NULL);

-- Down Migration

-- A deleted account has no password hash and a status the old list does not know, so the
-- rollback stops with a clear message instead of failing on a constraint half-way. There is
-- no safe automatic way back: restoring a hash would mean inventing a password.
DO $$
DECLARE
  deleted_count integer;
BEGIN
  SELECT count(*) INTO deleted_count FROM users WHERE status = 'deleted';
  IF deleted_count > 0 THEN
    RAISE EXCEPTION 'Cannot roll back users-deleted: % deleted account(s) exist. A deleted account has no password hash and a status the old schema does not allow. Roll back only on a database with no deleted accounts.', deleted_count;
  END IF;
END
$$;

-- The new rule first, by name, then the rules exactly as users-activation (password) and the
-- users migration (reason) wrote them, and the status list as users-activation left it.
ALTER TABLE users
  DROP CONSTRAINT users_deleted_has_no_public_key,
  DROP CONSTRAINT users_password_null_when_invited_or_deleted,
  ADD CONSTRAINT users_password_only_when_invited
    CHECK ((password_hash IS NULL) = (status = 'invited')),
  DROP CONSTRAINT users_status_reason_required,
  ADD CONSTRAINT users_status_reason_required
    CHECK (status NOT IN ('suspended', 'rejected')
           OR (status_reason IS NOT NULL AND btrim(status_reason) <> '')),
  DROP CONSTRAINT users_status_valid,
  ADD CONSTRAINT users_status_valid
    CHECK (status IN ('pending', 'active', 'suspended', 'rejected', 'invited'));
