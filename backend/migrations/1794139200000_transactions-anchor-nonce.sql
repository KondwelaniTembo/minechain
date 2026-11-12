-- Up Migration

-- What the anchoring worker needs to resend a stuck transaction safely (D6, 8 Nov plan).
--
-- anchor_nonce: the recorder wallet's nonce used for this step's transaction. A wallet's
-- transactions are numbered, and each number can be mined only once. If a transaction is
-- dropped, the worker re-signs it with the SAME nonce, so at most one of the two copies can
-- ever reach the chain: a non-idempotent recordHandoff can never be anchored twice. Without
-- the stored number the worker could only pick a fresh nonce, and then both copies could be
-- mined. bigint, like weight_mg; pg returns it as text.
--
-- anchor_submitted_at: when the row became submitted, by the server's clock. The worker
-- waits a grace period from here before treating an unseen transaction as dropped. It is
-- not compared with anchored_at, which is the block's timestamp from another clock.
--
-- Both stay set after confirmed and failed, as a record of how the step was sent. They
-- are cleared only when a dropped transaction is put back to pending.
--
-- Every existing row is pending (no worker has run yet), so the CHECKs cannot fail on
-- existing data.
ALTER TABLE transactions
  ADD COLUMN anchor_nonce        bigint,
  ADD COLUMN anchor_submitted_at timestamptz,
  -- "If submitted then both", written NOT A OR B as in the other anchor rules. Only
  -- submitted: a confirmed row found through the event logs after a crash may come from a
  -- transaction this row never recorded, and pending, failed or confirmed rows may keep
  -- earlier values.
  ADD CONSTRAINT transactions_submitted_needs_nonce
    CHECK (anchor_status <> 'submitted' OR (anchor_nonce IS NOT NULL AND anchor_submitted_at IS NOT NULL)),
  -- Nonces count up from 0.
  ADD CONSTRAINT transactions_anchor_nonce_non_negative
    CHECK (anchor_nonce IS NULL OR anchor_nonce >= 0);

-- Down Migration

-- The constraints are dropped first and by name, so the rollback says exactly what it
-- undoes instead of relying on DROP COLUMN removing them implicitly.
ALTER TABLE transactions
  DROP CONSTRAINT transactions_anchor_nonce_non_negative,
  DROP CONSTRAINT transactions_submitted_needs_nonce,
  DROP COLUMN anchor_submitted_at,
  DROP COLUMN anchor_nonce;
