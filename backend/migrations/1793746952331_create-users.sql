-- Up Migration

-- Shared by every table with an updated_at column. Defined once here so gps_zones,
-- consignments and transactions each need only a one-line CREATE TRIGGER later.
-- Note: now() is the time the current transaction started, not the exact moment.
CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TABLE users (
  -- Random rather than 1, 2, 3, so IDs in URLs cannot be guessed or counted.
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  username       text        NOT NULL,
  full_name      text        NOT NULL,
  -- Only miners and buyers hold licences; the admin checks it before approving.
  licence_number text,
  password_hash  text        NOT NULL,
  role           text        NOT NULL,
  -- New accounts wait for an admin (FR-12), so the safe default is no access.
  status         text        NOT NULL DEFAULT 'pending',
  status_reason  text,
  -- NULL until the phone registers its Android Keystore key.
  public_key     bytea,
  -- The user's on-chain identity. Random bytes made in Node, never derived from personal
  -- data, because a hash of a phone number or name could be reversed by guessing.
  actor_ref      bytea       NOT NULL,
  -- RESTRICT: an admin who approved others cannot be hard-deleted, or the record of who
  -- approved whom would be lost (D9).
  approved_by    uuid        REFERENCES users (id) ON DELETE RESTRICT,
  approved_at    timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),

  -- Plain characters only, so an admin cannot be fooled by spaces or look-alike letters.
  CONSTRAINT users_username_format
    CHECK (username ~ '^[A-Za-z0-9_.-]+$' AND char_length(username) BETWEEN 3 AND 32),
  CONSTRAINT users_full_name_not_blank
    CHECK (btrim(full_name) <> ''),
  -- Argon2id, or bcrypt as the approved fallback. A bug that tried to save a plain
  -- password fails here instead of storing it.
  CONSTRAINT users_password_is_hash
    CHECK (password_hash LIKE '$argon2id$%' OR password_hash LIKE '$2b$%'),
  -- CHECK rather than ENUM: adding or removing a value later is one small migration.
  CONSTRAINT users_role_valid
    CHECK (role IN ('miner', 'transporter', 'buyer', 'officer', 'admin')),
  CONSTRAINT users_status_valid
    CHECK (status IN ('pending', 'active', 'suspended', 'rejected')),
  -- A suspended or rejected user must be told why (FR-12, D1).
  CONSTRAINT users_status_reason_required
    CHECK (status NOT IN ('suspended', 'rejected')
           OR (status_reason IS NOT NULL AND btrim(status_reason) <> '')),
  -- A P-256 key exported by the Android Keystore (SubjectPublicKeyInfo, DER) is always
  -- 91 bytes. Any other length means a wrong format or key type.
  CONSTRAINT users_public_key_p256_spki
    CHECK (public_key IS NULL OR octet_length(public_key) = 91),
  -- Two users must never share an on-chain identity.
  CONSTRAINT users_actor_ref_unique UNIQUE (actor_ref),
  -- Matches the contract's bytes32 actor reference.
  CONSTRAINT users_actor_ref_32_bytes
    CHECK (octet_length(actor_ref) = 32),
  -- Who approved and when are set together or not at all.
  CONSTRAINT users_approval_complete
    CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
  -- When approved_by is NULL this gives NULL, which a CHECK lets through, so unapproved
  -- users are fine.
  CONSTRAINT users_no_self_approval
    CHECK (approved_by <> id)
);

-- Case-insensitive uniqueness: 'Banda' and 'banda' would be the same person to an admin.
-- Also makes login lookups written as lower(username) = lower($1) fast.
CREATE UNIQUE INDEX users_username_lower_key ON users (lower(username));

CREATE TRIGGER users_set_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Down Migration

-- Dropping the table also drops its trigger and index. The function goes last, because the
-- trigger depended on it.
DROP TABLE users;
DROP FUNCTION set_updated_at();
