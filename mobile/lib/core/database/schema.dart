// The local database's tables (plan §2, schema version 1) and how a file is
// brought up to date.
//
// Migrations: SQLite keeps one whole number in every file's header,
// `PRAGMA user_version`, which starts at 0. Each entry of [migrations] takes
// the file one version up. Opening runs the missing ones in order, each in
// its own transaction, and writes the new number in the same transaction, so
// a file is always at exactly one version, never half-way.
//
// Rule for later modules: never edit a migration once it has been on a
// phone; add a new one. Phones in the field already ran the old one.

import 'package:sqlite3/sqlite3.dart';

import 'database_failure.dart';

/// Version 1 (plan §2). One statement per entry.
///
/// STRICT tables: each column holds only its declared type. SQLite first
/// tries to convert a value to that type and refuses it only if the
/// conversion would lose something (sqlite.org/stricttables.html): text such
/// as 'many' in an INTEGER column, or a BLOB in a TEXT column. A number given
/// to a TEXT column is converted to text and stored, not refused. So STRICT
/// guarantees what comes back out (a TEXT column always gives text), not
/// that the app handed in text; the repository always passes the payload's
/// own text, so nothing is ever converted.
///
/// The signed values (`weight_mg`, `latitude`, `longitude`, `captured_at`)
/// are TEXT, exactly as in the payload, never numbers: the payload is the
/// truth, and these copies are only for lists.
const List<String> _schemaV1 = [
  '''
  CREATE TABLE local_steps (
    step_id TEXT NOT NULL PRIMARY KEY
      CHECK (length(step_id) = 36 AND step_id = lower(step_id)),
    actor_id TEXT NOT NULL,
    type TEXT NOT NULL
      CHECK (type IN ('registration', 'handoff', 'purchase')),
    qr_code TEXT NOT NULL,
    mineral TEXT,
    weight_mg TEXT NOT NULL,
    latitude TEXT NOT NULL,
    longitude TEXT NOT NULL,
    captured_at TEXT NOT NULL,
    payload TEXT NOT NULL,
    signature TEXT NOT NULL,
    key_fingerprint TEXT NOT NULL,
    gps_accuracy_m REAL,
    sync_state TEXT NOT NULL DEFAULT 'queued'
      CHECK (sync_state IN ('queued', 'deferred', 'synced', 'flagged', 'rejected')),
    review_status TEXT,
    server_transaction_id TEXT,
    last_code TEXT,
    last_message TEXT,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at TEXT,
    first_deferred_at TEXT,
    synced_at TEXT,
    created_at TEXT NOT NULL,
    -- A registration names its mineral; a handoff or purchase never does
    -- (signing spec, section 3).
    CHECK ((type = 'registration') = (mineral IS NOT NULL))
  ) STRICT
  ''',
  // Lists and sync read one actor's rows in time order.
  'CREATE INDEX local_steps_actor_created ON local_steps (actor_id, created_at)',
  // The duplicate check before a registration (plan §6).
  'CREATE INDEX local_steps_qr_type ON local_steps (qr_code, type)',
  // Small settings such as the last mineral chosen. Nothing secret here.
  '''
  CREATE TABLE settings (
    key TEXT NOT NULL PRIMARY KEY,
    value TEXT NOT NULL
  ) STRICT
  ''',
];

/// Migration N (counting from 1) takes a file from version N-1 to N.
const List<List<String>> migrations = [_schemaV1];

/// The version this app writes.
int get currentSchemaVersion => migrations.length;

/// Brings [db] up to [currentSchemaVersion]. Throws [DatabaseTooNew] for a
/// file from a newer app, and [DatabaseOpenFailed] if a migration fails
/// (that migration is rolled back; the file stays at its old version).
void migrate(Database db) {
  final int found;
  try {
    found = db.userVersion;
  } on SqliteException {
    throw const DatabaseOpenFailed('read-version');
  }
  if (found > currentSchemaVersion) throw DatabaseTooNew(found);

  for (var version = found + 1; version <= currentSchemaVersion; version++) {
    try {
      // IMMEDIATE takes the write lock at once, so no other connection can
      // slip in between reading the version and changing the tables.
      db.execute('BEGIN IMMEDIATE');
      for (final statement in migrations[version - 1]) {
        db.execute(statement);
      }
      db.userVersion = version;
      db.execute('COMMIT');
    } on SqliteException {
      try {
        db.execute('ROLLBACK');
      } on SqliteException {
        // Nothing more to undo.
      }
      throw DatabaseOpenFailed('migration-$version');
    }
  }
}
