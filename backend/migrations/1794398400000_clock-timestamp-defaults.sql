-- Up Migration

-- Two timestamps whose ORDER matters inside one database transaction now default to the
-- time of the INSERT itself, clock_timestamp(), instead of now(), which is when the
-- transaction STARTED.
--
-- transactions.received_at: the anchoring queue and the reports order a consignment's steps
-- by it, so it must follow custody order. With now(), a handoff whose transaction began just
-- before its registration committed could get the earlier time (decisions.md, 9 Nov). Sync
-- already writes clock_timestamp() explicitly.
--
-- alerts.created_at: an alert is inserted after its step in the same transaction, and the
-- audit trail orders it after that step. With now() it would carry the transaction's start
-- time, earlier than its own step's received_at, so the trail would list the alert first
-- (Fix 3, 11 Nov). Sync already writes clock_timestamp() explicitly.
--
-- Sync keeps writing the value explicitly; this changes only what a future INSERT gets when
-- it leaves the column out (verification, an import, a script), so the trap cannot come back
-- by accident. Existing rows are not changed: a default applies only to new rows. Alerts
-- stored before Fix 3 keep their earlier times (a known limitation in decisions.md).
ALTER TABLE transactions
  ALTER COLUMN received_at SET DEFAULT clock_timestamp();

ALTER TABLE alerts
  ALTER COLUMN created_at SET DEFAULT clock_timestamp();

-- Down Migration

-- Back to the original defaults. Rows written in between keep their values.
ALTER TABLE alerts
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE transactions
  ALTER COLUMN received_at SET DEFAULT now();
