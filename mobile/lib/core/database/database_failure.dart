// Every way opening the encrypted local database can fail, as a small fixed
// set of types (plan M3).
//
// The rule behind them: if the existing database cannot be opened, the app
// STOPS. It never makes a new key or a new empty file in place of the old
// one, because the old file holds signed work that has not been sent yet
// (NFR-04). A failure is shown; the file stays as it was.
//
// SECURITY: these carry no text from SQLite. A SqliteException remembers the
// statement that failed (`causingStatement`) and prints it in toString(), and
// for `PRAGMA key` that statement contains the key. So the opening code turns
// every SqliteException into one of these, and drops the original.
//
// Plain Dart, and plain fields only, so they can be sent back from the
// background isolate that opens the database.

sealed class DatabaseFailure implements Exception {
  const DatabaseFailure();
}

/// The secure store could not be read or written, or holds a value that is
/// not a key. Nothing was opened or created.
final class DatabaseKeyUnavailable extends DatabaseFailure {
  const DatabaseKeyUnavailable();

  @override
  String toString() => 'DatabaseKeyUnavailable()';
}

/// There is a database file but no key for it: the key was lost (for
/// example the app's secure storage was cleared). The file cannot be read
/// without it, and is left untouched.
final class DatabaseKeyMissing extends DatabaseFailure {
  const DatabaseKeyMissing();

  @override
  String toString() => 'DatabaseKeyMissing()';
}

/// This build's SQLite has no encryption (the sqlite3mc library is not the
/// one loaded). Refused before anything is written, so no unencrypted file
/// is ever made.
final class DatabaseCipherUnavailable extends DatabaseFailure {
  const DatabaseCipherUnavailable();

  @override
  String toString() => 'DatabaseCipherUnavailable()';
}

/// The file could not be read with the key: a wrong key, or not a database.
final class DatabaseWrongKey extends DatabaseFailure {
  const DatabaseWrongKey();

  @override
  String toString() => 'DatabaseWrongKey()';
}

/// The file was made by a newer version of the app (its schema version is
/// higher than this app knows). Opening it with old code could damage it.
final class DatabaseTooNew extends DatabaseFailure {
  const DatabaseTooNew(this.version);
  final int version;

  @override
  String toString() => 'DatabaseTooNew(version: $version)';
}

/// Anything else SQLite refused while opening or setting up (a full disk, a
/// failed migration). [stage] says where, for the developer; no SQLite text.
final class DatabaseOpenFailed extends DatabaseFailure {
  const DatabaseOpenFailed(this.stage);
  final String stage;

  @override
  String toString() => 'DatabaseOpenFailed(stage: $stage)';
}
