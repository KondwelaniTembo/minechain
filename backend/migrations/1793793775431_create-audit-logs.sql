-- Up Migration

-- A chronological record of every action, for regulatory compliance (FR-05, FR-13).
-- Append-only: rows can be added and read, never changed or removed.
CREATE TABLE audit_logs (
  -- A number, not a UUID: it shows insert order at a glance, is smaller, and is never made
  -- offline (D8). ALWAYS: PostgreSQL picks it, and a value supplied by hand is refused.
  -- Gaps are normal (a rolled-back insert still uses up a number), so a missing number is
  -- not evidence of a deleted row.
  id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  -- NULL for system actions and for failed logins with an unknown username. RESTRICT:
  -- users with log entries cannot be hard-deleted. CASCADE or SET NULL would be blocked by
  -- the append-only triggers anyway, because they quietly delete or update log rows.
  actor_id    uuid        REFERENCES users (id) ON DELETE RESTRICT,
  action      text        NOT NULL,
  -- What the entry is about, in any table, so there is no foreign key: a log must outlive
  -- what it describes and must never block a delete.
  entity_type text,
  entity_id   uuid,
  -- Never passwords, tokens or keys; the service decides what goes in here.
  details     jsonb       NOT NULL DEFAULT '{}',
  -- Personal data, so it stays in this database and never goes on-chain. inet rejects
  -- anything that is not a valid IPv4 or IPv6 address.
  ip_address  inet,

  -- area.verb, for example user.login or alert.dismiss, so FR-13 trails can filter by it.
  CONSTRAINT audit_logs_action_format
    CHECK (action ~ '^[a-z_]+\.[a-z_]+$'),
  -- A fixed list, like the mineral list, so a trail for one consignment never misses rows
  -- because of spelling.
  CONSTRAINT audit_logs_entity_type_valid
    CHECK (entity_type IS NULL
           OR entity_type IN ('user', 'gps_zone', 'consignment', 'transaction', 'alert')),
  -- A type and an id are given together or not at all.
  CONSTRAINT audit_logs_entity_complete
    CHECK ((entity_type IS NULL) = (entity_id IS NULL)),
  CONSTRAINT audit_logs_details_is_object
    CHECK (jsonb_typeof(details) = 'object')
);

-- FR-13 trails per actor and per consignment (or other entity), and date-range reports.
CREATE INDEX audit_logs_actor_occurred_idx  ON audit_logs (actor_id, occurred_at);
CREATE INDEX audit_logs_entity_occurred_idx ON audit_logs (entity_type, entity_id, occurred_at);
CREATE INDEX audit_logs_occurred_at_idx     ON audit_logs (occurred_at);

-- One function for every refused operation. TG_OP holds 'UPDATE', 'DELETE' or 'TRUNCATE'.
-- RAISE EXCEPTION stops the statement with error P0001 and rolls back what it had done.
CREATE FUNCTION audit_logs_reject_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'audit_logs is append-only: % is not allowed', TG_OP
    USING HINT = 'Record a correction as a new audit entry instead.';
END;
$$;

-- BEFORE: nothing is changed, not even briefly. FOR EACH STATEMENT: fires once per
-- statement even when no rows match, so any UPDATE or DELETE is refused whatever its WHERE.
CREATE TRIGGER audit_logs_no_update_or_delete
  BEFORE UPDATE OR DELETE ON audit_logs
  FOR EACH STATEMENT EXECUTE FUNCTION audit_logs_reject_change();

-- TRUNCATE empties a table without deleting row by row, so DELETE triggers never see it.
CREATE TRIGGER audit_logs_no_truncate
  BEFORE TRUNCATE ON audit_logs
  FOR EACH STATEMENT EXECUTE FUNCTION audit_logs_reject_change();

-- HONEST LIMIT: these triggers protect the log from the application, not from a person with
-- full database access. Today one database user runs the migrations and the app, so it owns
-- this table and could run ALTER TABLE ... DISABLE TRIGGER, DROP TABLE, or restore a
-- doctored backup. Future hardening: run migrations as a separate owner role and give the
-- app's role only INSERT and SELECT on audit_logs; add hash-chaining or periodic on-chain
-- anchoring of the log so changes are detectable.

-- Down Migration

-- DROP TABLE does not fire the triggers, so it works, and it destroys the log. Never run
-- this against a database whose log matters.
DROP TABLE audit_logs;
DROP FUNCTION audit_logs_reject_change();
