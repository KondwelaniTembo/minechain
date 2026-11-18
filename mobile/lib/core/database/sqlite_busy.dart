// Telling "the file is in use right now" apart from every other SQLite
// refusal.
//
// SQLITE_BUSY (5): another connection holds a lock on the file, for example
// one that is closing and folding the write-ahead log back into the file.
// SQLITE_LOCKED (6): the same, inside one connection. Both pass: trying again
// a moment later works. Neither says anything about the key or the file.

import 'package:sqlite3/sqlite3.dart';

const int _sqliteBusy = 5;
const int _sqliteLocked = 6;

/// True when [e] means "busy, try again". The low byte of the extended code
/// is the primary code (SQLITE_BUSY_SNAPSHOT is 517, and 517 & 0xff is 5).
bool isBusyOrLocked(SqliteException e) {
  final primary = e.extendedResultCode & 0xff;
  return primary == _sqliteBusy || primary == _sqliteLocked;
}
