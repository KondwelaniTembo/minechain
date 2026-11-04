-- Up Migration

-- One row per failed check on a step (FR-08). A consignment is "held" while any alert on
-- its steps is open (D3), so closing the last open alert releases the hold.
--
-- Left to the service, because a CHECK cannot see other rows or tables: the reviewer is an
-- officer, severity follows from the type, an alert never goes back to open, and the
-- step's review_status changes with the decision (reviewed -> rejected,
-- dismissed -> cleared) in the same database transaction.
CREATE TABLE alerts (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- RESTRICT: a step that raised an alert cannot be deleted, or the alert would lose its
  -- evidence.
  transaction_id uuid        NOT NULL REFERENCES transactions (id) ON DELETE RESTRICT,
  type           text        NOT NULL,
  severity       text        NOT NULL,
  -- Machine-readable facts behind the alert, for example expected and actual weight.
  details        jsonb       NOT NULL DEFAULT '{}',
  status         text        NOT NULL DEFAULT 'open',
  reviewed_by    uuid        REFERENCES users (id) ON DELETE RESTRICT,
  review_notes   text,
  -- No updated_at: the review is the only change, and reviewed_at records it.
  reviewed_at    timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),

  -- The five sync checks plus record_tampered, raised when a database record no longer
  -- matches the hash anchored on-chain (contract spec §7, D7).
  CONSTRAINT alerts_type_valid
    CHECK (type IN ('duplicate_consignment', 'quantity_discrepancy', 'gps_zone',
                    'invalid_signature', 'handoff_order', 'record_tampered')),
  CONSTRAINT alerts_severity_valid
    CHECK (severity IN ('low', 'medium', 'high')),
  -- reviewed: anomaly confirmed. dismissed: false positive.
  CONSTRAINT alerts_status_valid
    CHECK (status IN ('open', 'reviewed', 'dismissed')),
  -- Report code reads fields such as details.expectedWeight, so arrays and bare values
  -- are refused.
  CONSTRAINT alerts_details_is_object
    CHECK (jsonb_typeof(details) = 'object'),
  -- One alert per rule per step, so a re-run of the checks cannot pile up duplicates.
  -- Also serves as the index for the foreign key and for "alerts on this step".
  CONSTRAINT alerts_one_per_rule_per_step
    UNIQUE (transaction_id, type),
  -- Both directions in one rule: an open alert has no review fields, and a closed one has
  -- all of them, with non-blank notes (the proposal asks for justification notes). Each
  -- branch only uses IS NULL / IS NOT NULL and AND, so it can never give NULL and slip
  -- through.
  CONSTRAINT alerts_review_fields_match_status
    CHECK (CASE WHEN status = 'open'
                THEN reviewed_by IS NULL AND reviewed_at IS NULL AND review_notes IS NULL
                ELSE reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL
                     AND review_notes IS NOT NULL AND btrim(review_notes) <> ''
           END)
);

-- The officer's queue: open alerts, oldest first. Partial, so it stays small however many
-- alerts have been closed. reviewed_by gets no index: reviews are never listed per officer,
-- and D9 already blocks hard-deleting users.
CREATE INDEX alerts_open_queue_idx ON alerts (created_at) WHERE status = 'open';

-- Down Migration

DROP TABLE alerts;
