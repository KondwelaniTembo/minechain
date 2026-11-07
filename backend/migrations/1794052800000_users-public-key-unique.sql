-- Up Migration

-- A device key belongs to one account. Android Keystore keys are made per app install, so
-- the same key on two accounts means a bug, or one phone acting as two parties (for example
-- a miner and a buyer signing both ends of one consignment). A check before the UPDATE
-- could race with a second registration; only a unique index decides atomically.
--
-- NULLs never clash in a unique index, so any number of accounts can have no key yet. Every
-- row is NULL until the key registration endpoint exists, so this cannot fail on existing
-- data.
--
-- Known limit: after an admin key reset the old key is free again, so it could in theory be
-- registered on another account. Blocking that would mean checking every
-- transactions.signer_public_key ever stored (see docs/decisions.md).
CREATE UNIQUE INDEX users_public_key_key ON users (public_key);

-- Down Migration

DROP INDEX users_public_key_key;
