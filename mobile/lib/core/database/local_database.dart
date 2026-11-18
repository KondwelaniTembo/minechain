// The app's encrypted local database (plan M3), and how work reaches it
// without freezing the screen.
//
// package:sqlite3 is synchronous: a query blocks the thread that runs it. The
// UI runs on Dart's main isolate, so a slow query there (or the first open)
// would freeze the screen. So every piece of work is sent to a fresh
// background isolate with Isolate.run: it opens the file, does the work,
// closes the file, and sends back the result.
//
// An isolate is Dart's version of a thread, with its own memory: nothing is
// shared, values are copied in and out. That is why the work is a function
// of the Database plus plain values (strings, numbers, maps), and why the
// result must be plain values too.
//
// Why open per call, and not keep one connection in a long-lived isolate:
// it is far less code, nothing is left open if the app is killed, and with
// a raw key there is no slow passphrase stretching, so opening costs little.
// The integration test measures it; if it turns out slow on the A57, a
// long-lived worker isolate can replace this class without changing callers.
//
// One call at a time: each call opens and closes the file, and the last
// connection to close folds the write-ahead log back into the file under an
// exclusive lock. Two calls at once (the mineral being remembered and the
// send after a save, on the emulator) then meet that lock. So calls wait
// in line here, and the file never has two of this app's connections at
// once. The busy timeout (open_encrypted.dart) still covers anything else.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../storage/secure_store.dart';
import 'database_failure.dart';
import 'database_key.dart';
import 'open_encrypted.dart';
import 'schema.dart';

/// Somewhere to run database work.
abstract interface class LocalDatabase {
  /// Runs [work] against the open database and returns its result.
  ///
  /// [work] and its result must be sendable between isolates: use a
  /// top-level or static function, or a closure that captures only plain
  /// values, never an object holding a platform channel or a ref.
  Future<T> run<T>(T Function(Database db) work);
}

/// The real database: an encrypted file, opened on a background isolate for
/// each call.
class EncryptedLocalDatabase implements LocalDatabase {
  EncryptedLocalDatabase._(this._path, this._keyHex);

  final String _path;
  final String _keyHex;

  /// The end of the line of calls: the next call starts after it.
  Future<void> _tail = Future<void>.value();

  /// The file's name inside the app's private support folder.
  static const String fileName = 'minechain.db';

  /// Finds or makes the key, then opens the file once (on a background
  /// isolate) to prove the key works and to run any migrations.
  ///
  /// Throws a [DatabaseFailure]; never replaces an existing file.
  static Future<EncryptedLocalDatabase> open({
    required SecureStore store,
    required String directory,
  }) async {
    final path = '$directory${Platform.pathSeparator}$fileName';
    final keyHex = await DatabaseKeyStore(store)
        .readOrCreate(databaseExists: File(path).existsSync());

    // Only plain strings go into the closure, so it can be sent.
    await Isolate.run(() => openEncrypted(path, keyHex).close());
    return EncryptedLocalDatabase._(path, keyHex);
  }

  @override
  Future<T> run<T>(T Function(Database db) work) {
    final path = _path;
    final keyHex = _keyHex;
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    // Waits for the call before, whatever it came to (its caller has its
    // error; `_tail` itself never fails), then runs; the next call waits
    // for this one.
    return previous
        .then((_) => _inIsolate(path, keyHex, work))
        .whenComplete(done.complete);
  }

  /// Static, and given only two strings and the work function, so the
  /// closure sent to the isolate captures nothing else (not `this`, not the
  /// Completer, which cannot be sent).
  static Future<T> _inIsolate<T>(
    String path,
    String keyHex,
    T Function(Database db) work,
  ) => Isolate.run(() {
    final db = openEncrypted(path, keyHex);
    try {
      return work(db);
    } finally {
      db.close();
    }
  });

  // The path and key are not printed.
  @override
  String toString() => 'EncryptedLocalDatabase()';
}

/// TEST ONLY in practice: an unencrypted database in memory, on the calling
/// isolate, with the same schema. Used by the repository tests on the
/// laptop. The encryption itself is proved on the phone by
/// integration_test/db_encryption_test.dart.
class InMemoryLocalDatabase implements LocalDatabase {
  InMemoryLocalDatabase() : db = sqlite3.openInMemory() {
    migrate(db);
  }

  final Database db;

  @override
  Future<T> run<T>(T Function(Database db) work) async => work(db);

  void close() => db.close();
}

/// The app's database, opened once and then kept.
///
/// A FutureProvider: opening needs the secure store and the folder, both
/// asynchronous. A failure is a DatabaseFailure in the provider's error, and
/// is NOT retried by itself (noRetry): a wrong or missing key will not fix
/// itself, and the screen that needs the database shows why.
final localDatabaseProvider = FutureProvider<LocalDatabase>((ref) async {
  // Application support: private to the app, not shown to the user, not
  // cleared as a cache would be. Backups of it are off (decision Mobile (14)).
  final directory = await getApplicationSupportDirectory();
  return EncryptedLocalDatabase.open(
    store: ref.watch(secureStoreProvider),
    directory: directory.path,
  );
});
