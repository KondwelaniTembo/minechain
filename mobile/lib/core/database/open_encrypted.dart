// Opening the database file with its key (decision Mobile (1), plan M3).
//
// This runs inside a background isolate (local_database.dart), so it is
// plain, synchronous code: package:sqlite3 calls SQLite directly through FFI,
// and every call blocks the thread it runs on. On a background isolate that
// is fine; on the UI isolate it would freeze the screen.
//
// The order matters, and each step has a reason:
//   1. PRAGMA cipher='sqlcipher' and PRAGMA legacy=4 BEFORE the key. They say
//      which encryption scheme the key is for; SQLite3MultipleCiphers applies
//      the scheme when the key is set, so after the key it is too late and
//      the file would use the library's own default scheme instead.
//   2. Check that the cipher is really there. Plain SQLite ignores pragmas it
//      does not know, so without this check a build without encryption
//      would open, save and look normal while writing an unencrypted file.
//   3. PRAGMA key, then a READ. Setting a key never fails by itself; only
//      reading shows whether it is the right one ("file is not a database").
//   4. Only then WAL, synchronous=FULL and migrations: nothing is written to
//      a file that has not been proved to be ours.
//
// And before all of them, the busy timeout. It is a setting of this
// connection only and touches no file, so it is safe before the key. It must
// come before the first read (step 3): when another connection is closing,
// SQLite folds the write-ahead log back into the file under an exclusive
// lock, and without a timeout a read in that moment fails at once with
// SQLITE_BUSY. On the API 26 emulator exactly that made the send after a
// save report "cannot be opened": the busy read was taken for a wrong key.

import 'package:sqlite3/sqlite3.dart';

import 'database_failure.dart';
import 'database_key.dart';
import 'schema.dart';
import 'sqlite_busy.dart';

/// How long a connection waits for another one's lock before giving up.
const int busyTimeoutMs = 5000;

/// Opens [path] with [keyHex] (64 hex characters) and brings its schema up
/// to date. The caller must close the result.
///
/// Throws only [DatabaseFailure]s; no SqliteException ever leaves this
/// function (see database_failure.dart for why).
Database openEncrypted(String path, String keyHex) {
  // The key goes into the PRAGMA as text, because PRAGMAs cannot take bound
  // parameters. That is the one exception to "parameterised SQL only", and
  // it is safe because only these 64 hex characters can get in.
  if (!isDatabaseKeyHex(keyHex)) throw const DatabaseKeyUnavailable();

  final Database db;
  try {
    db = sqlite3.open(path);
  } on SqliteException {
    throw const DatabaseOpenFailed('open');
  }

  try {
    _setBusyTimeout(db);
    _setCipher(db);
    _setKey(db, keyHex);
    _setUp(db);
    migrate(db);
    return db;
  } catch (_) {
    db.close();
    rethrow;
  }
}

void _setBusyTimeout(Database db) {
  try {
    // Two isolates may open the file at once; wait for the other's lock
    // instead of failing straight away.
    db.execute('PRAGMA busy_timeout = $busyTimeoutMs');
  } on SqliteException {
    throw const DatabaseOpenFailed('busy-timeout');
  }
}

void _setCipher(Database db) {
  try {
    db.execute("PRAGMA cipher = 'sqlcipher'");
    db.execute('PRAGMA legacy = 4');
    final answer = db.select('PRAGMA cipher');
    if (answer.isEmpty || answer.first.columnAt(0) != 'sqlcipher') {
      throw const DatabaseCipherUnavailable();
    }
  } on SqliteException {
    throw const DatabaseCipherUnavailable();
  }
}

void _setKey(Database db, String keyHex) {
  try {
    // x'...' is SQLCipher's form for a raw 256-bit key: it is used as it is,
    // with no slow passphrase stretching, because it is already random.
    db.execute('PRAGMA key = "x\'$keyHex\'"');
  } on SqliteException {
    // Never rethrown: this exception's text would contain the key.
    throw const DatabaseWrongKey();
  }
  try {
    // The proof: SQLite must decrypt page 1 to answer this.
    db.select('SELECT count(*) FROM sqlite_master');
  } on SqliteException catch (e) {
    // Busy says nothing about the key: the page was never read.
    if (isBusyOrLocked(e)) throw const DatabaseBusy('key-check');
    throw const DatabaseWrongKey();
  }
}

void _setUp(Database db) {
  try {
    // WAL ("write-ahead log"): changes go to a side file first and are
    // folded into the main file later. Readers never wait for a writer, and
    // a crash mid-write leaves the main file whole.
    db.select('PRAGMA journal_mode = WAL');
    // FULL: a commit is on the storage before it returns, so a row that was
    // reported as saved survives a flat battery (NFR-04).
    db.execute('PRAGMA synchronous = FULL');
  } on SqliteException catch (e) {
    if (isBusyOrLocked(e)) throw const DatabaseBusy('setup');
    throw const DatabaseOpenFailed('setup');
  }
}
