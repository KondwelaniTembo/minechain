-- Up Migration

-- One row per signed custody step: registration, handoff or purchase. The signed fields are
-- the evidence; the review and anchoring fields track what happened to it afterwards.
--
-- Rules that need other tables or live data are left to the service, because a CHECK
-- cannot see them: the actor's role matches the step type, stage order, the 10% weight
-- check, the GPS point lying inside zone_id, and the signature actually verifying.
CREATE TABLE transactions (
  id                uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  consignment_id    uuid         NOT NULL REFERENCES consignments (id) ON DELETE RESTRICT,
  actor_id          uuid         NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  type              text         NOT NULL,
  -- Made by the phone when it signs, and part of the signed record, so a retried or
  -- replayed sync of the same record carries the same key and creates no second row.
  idempotency_key   uuid         NOT NULL,
  -- Whole milligrams, as in the contract. The largest bigint is below the largest uint64,
  -- so any weight allowed here also fits on-chain.
  weight_mg         bigint       NOT NULL,
  -- Exact decimals, not float, so the stored point matches the signed one. Six places is
  -- about 11 cm.
  -- SERVICE LAYER: numeric(9,6) silently rounds extra decimal places (25.1234567 is stored
  -- as 25.123457), which would make the column differ from the signed payload. The app
  -- must round latitude and longitude to 6 decimals *before* signing, and the API must
  -- reject any coordinate with more than 6 decimal places instead of letting it be rounded.
  latitude          numeric(9,6) NOT NULL,
  longitude         numeric(9,6) NOT NULL,
  -- The zone the point fell in when the GPS check ran. NULL means outside every zone.
  zone_id           uuid         REFERENCES gps_zones (id) ON DELETE RESTRICT,
  -- The phone's time, covered by the signature. Can be up to 72 hours before received_at.
  captured_at       timestamptz  NOT NULL,
  received_at       timestamptz  NOT NULL DEFAULT now(),
  -- The exact string the phone signed. text, not jsonb: jsonb reorders keys and drops
  -- whitespace, and the signature only verifies against the original bytes.
  signed_payload    text         NOT NULL,
  signature         bytea        NOT NULL,
  -- The key that was valid at signing time, so old steps still verify after a lost phone
  -- leads to a new key on users (D5).
  signer_public_key bytea        NOT NULL,
  -- The hash anchored on-chain. hash_version says which scheme made it, because the scheme
  -- must never change for rows already anchored (contract spec §7).
  data_hash         bytea        NOT NULL,
  hash_version      smallint     NOT NULL DEFAULT 1,
  review_status     text         NOT NULL,
  anchor_status     text         NOT NULL DEFAULT 'pending',
  chain_tx_hash     bytea,
  block_number      bigint,
  anchor_attempts   integer      NOT NULL DEFAULT 0,
  anchor_error      text,
  anchored_at       timestamptz,
  updated_at        timestamptz  NOT NULL DEFAULT now(),

  CONSTRAINT transactions_type_valid
    CHECK (type IN ('registration', 'handoff', 'purchase')),
  -- Per actor, so one user's keys can never block another user's steps.
  CONSTRAINT transactions_idempotency_key_unique
    UNIQUE (actor_id, idempotency_key),
  CONSTRAINT transactions_weight_positive
    CHECK (weight_mg > 0),
  CONSTRAINT transactions_latitude_range
    CHECK (latitude BETWEEN -90 AND 90),
  CONSTRAINT transactions_longitude_range
    CHECK (longitude BETWEEN -180 AND 180),
  CONSTRAINT transactions_signed_payload_not_blank
    CHECK (btrim(signed_payload) <> ''),
  -- A DER-encoded P-256 ECDSA signature is at most 72 bytes.
  CONSTRAINT transactions_signature_der_length
    CHECK (octet_length(signature) BETWEEN 8 AND 72),
  CONSTRAINT transactions_signer_key_p256_spki
    CHECK (octet_length(signer_public_key) = 91),
  CONSTRAINT transactions_data_hash_32_bytes
    CHECK (octet_length(data_hash) = 32),
  CONSTRAINT transactions_hash_version_positive
    CHECK (hash_version >= 1),
  -- passed: all checks passed. flagged: a check failed, awaiting an officer.
  -- cleared: an officer dismissed the alert. rejected: an officer confirmed the anomaly.
  CONSTRAINT transactions_review_status_valid
    CHECK (review_status IN ('passed', 'flagged', 'cleared', 'rejected')),
  -- submitted is the gap between "sent to Sepolia" and "mined". The worker checks
  -- chain_tx_hash on-chain before resending, so a crash cannot cause a second handoff (D6).
  CONSTRAINT transactions_anchor_status_valid
    CHECK (anchor_status IN ('pending', 'submitted', 'confirmed', 'failed')),
  CONSTRAINT transactions_chain_tx_hash_32_bytes
    CHECK (chain_tx_hash IS NULL OR octet_length(chain_tx_hash) = 32),
  -- NULLs never clash, so any number of rows can have no hash yet. One Sepolia transaction
  -- anchors exactly one step.
  CONSTRAINT transactions_chain_tx_hash_unique
    UNIQUE (chain_tx_hash),
  -- "If A then B" is written NOT A OR B, because SQL has no "if".
  CONSTRAINT transactions_sent_needs_tx_hash
    CHECK (anchor_status NOT IN ('submitted', 'confirmed') OR chain_tx_hash IS NOT NULL),
  CONSTRAINT transactions_confirmed_needs_block
    CHECK (anchor_status <> 'confirmed' OR (block_number IS NOT NULL AND anchored_at IS NOT NULL)),
  CONSTRAINT transactions_failed_needs_error
    CHECK (anchor_status <> 'failed' OR (anchor_error IS NOT NULL AND btrim(anchor_error) <> '')),
  -- A flagged or rejected step can never be sent to the chain, and a step that was sent
  -- can never be changed to flagged or rejected.
  CONSTRAINT transactions_anchor_only_if_approved
    CHECK (anchor_status = 'pending' OR review_status IN ('passed', 'cleared')),
  CONSTRAINT transactions_block_number_positive
    CHECK (block_number IS NULL OR block_number > 0),
  CONSTRAINT transactions_anchor_attempts_non_negative
    CHECK (anchor_attempts >= 0)
);

-- Partial unique indexes: unique only among accepted steps. Flagged and rejected duplicate
-- attempts are kept as the evidence behind duplicate_consignment alerts. Handoffs get no
-- such rule, because one journey can have several transporters.
CREATE UNIQUE INDEX transactions_one_accepted_registration_idx
  ON transactions (consignment_id)
  WHERE type = 'registration' AND review_status IN ('passed', 'cleared');

CREATE UNIQUE INDEX transactions_one_accepted_purchase_idx
  ON transactions (consignment_id)
  WHERE type = 'purchase' AND review_status IN ('passed', 'cleared');

-- FR-09 report filters and custody-chain lookups. Each also covers a foreign key, which
-- PostgreSQL does not index by itself.
CREATE INDEX transactions_consignment_received_idx ON transactions (consignment_id, received_at);
CREATE INDEX transactions_actor_received_idx       ON transactions (actor_id, received_at);
CREATE INDEX transactions_zone_captured_idx        ON transactions (zone_id, captured_at);
CREATE INDEX transactions_captured_at_idx          ON transactions (captured_at);

-- Verification (contract spec §7) looks rows up by their anchored hash.
CREATE INDEX transactions_data_hash_idx ON transactions (data_hash);

-- The anchoring worker's queue, oldest first: only approved steps still to be sent or
-- confirmed. The worker's query must repeat both conditions for PostgreSQL to use it.
CREATE INDEX transactions_anchor_queue_idx
  ON transactions (received_at)
  WHERE anchor_status IN ('pending', 'submitted')
    AND review_status IN ('passed', 'cleared');

CREATE TRIGGER transactions_set_updated_at
  BEFORE UPDATE ON transactions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Down Migration

DROP TABLE transactions;
