// Proof, on the phone, that the local database is really encrypted (decision
// Mobile (1): "Encryption is to be proven on the A57 by a test, not assumed").
//
// Run with:  flutter test integration_test/db_encryption_test.dart -d <device id>
//
// Why on the phone: what must be proved is the library inside the ANDROID
// app, the one the build hook bundled for arm64. The laptop's tests load the
// Windows build of the same library, which proves nothing about this one.
//
// This test uses its own files (a random name in the app's support folder)
// and its own random key: never the app's minechain.db and never the key in
// secure storage. It deletes its files at the end, including SQLite's -wal
// and -shm side files.
//
// The plan's six checks:
//   1. open, write a row, close;
//   2. the file's first 16 bytes are NOT "SQLite format 3\0";
//   3. opening with no key fails, and with a wrong key fails;
//   4. opening with the right key reads the row back;
//   5. PRAGMA cipher answers "sqlcipher";
//   6. the control: a plain file DOES start with "SQLite format 3\0", so
//      check 2 would catch an unencrypted build.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:minechain/core/database/database_failure.dart';
import 'package:minechain/core/database/open_encrypted.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Every SQLite file starts with these 16 bytes, unless it is encrypted.
final List<int> plainHeader = ascii.encode('SQLite format 3\u0000');

String randomHex(int bytes) {
  final random = Random.secure();
  return List.generate(
    bytes,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

List<int> firstBytes(String path, int count) {
  final file = File(path).openSync();
  try {
    return file.readSync(count);
  } finally {
    file.closeSync();
  }
}

void deleteWithSideFiles(String path) {
  for (final suffix in ['', '-wal', '-shm', '-journal']) {
    final file = File('$path$suffix');
    if (file.existsSync()) file.deleteSync();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String path;
  late String key;

  setUp(() async {
    final directory = await getApplicationSupportDirectory();
    // Its own name, never minechain.db.
    path = '${directory.path}/encryption_test_${randomHex(8)}.db';
    key = randomHex(32);
  });

  tearDown(() => deleteWithSideFiles(path));

  testWidgets('the six checks', (tester) async {
    // 1. Open, write, close.
    final stopwatch = Stopwatch()..start();
    var db = openEncrypted(path, key);
    stopwatch.stop();
    db.execute('INSERT INTO settings (key, value) VALUES (?, ?)', [
      'probe',
      'gold river kasempa',
    ]);
    db.close(); // the last connection: WAL is folded into the main file

    // 2. Not a plain SQLite header.
    expect(File(path).existsSync(), isTrue);
    expect(firstBytes(path, 16), isNot(plainHeader));
    // The row's text is nowhere in the file in clear.
    final everything = File(path).readAsBytesSync();
    expect(
      latin1.decode(everything, allowInvalid: true),
      isNot(contains('gold river kasempa')),
    );

    // 3a. No key: plain SQLite cannot read it.
    final noKey = sqlite3.open(path);
    try {
      expect(
        () => noKey.select('SELECT * FROM sqlite_master'),
        throwsA(isA<SqliteException>()),
      );
    } finally {
      noKey.close();
    }

    // 3b. A wrong key: refused with the typed failure, nothing else.
    expect(
      () => openEncrypted(path, randomHex(32)),
      throwsA(isA<DatabaseWrongKey>()),
    );

    // 4. The right key reads the row back.
    db = openEncrypted(path, key);
    try {
      final rows = db.select('SELECT value FROM settings WHERE key = ?', [
        'probe',
      ]);
      expect(rows.single['value'], 'gold river kasempa');

      // 5. The cipher in use is SQLCipher's scheme.
      expect(db.select('PRAGMA cipher').first.columnAt(0), 'sqlcipher');
      // And the schema is there, at the current version. Changed by decision
      // (Transporter handoff T2, the mineral hint): 2, not 1.
      expect(db.userVersion, 2);
    } finally {
      db.close();
    }

    // Opening must be quick: a raw key needs no slow passphrase stretching.
    // If this fails, the x'...' raw key form was not recognised and the key
    // is being stretched like a passphrase on every open (still encrypted,
    // but too slow for opening per call; see local_database.dart).
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  testWidgets('6. control: a plain SQLite file does start with the header', (
    tester,
  ) async {
    final plain = sqlite3.open(path);
    plain.execute('CREATE TABLE t (x TEXT)');
    plain.close();

    expect(firstBytes(path, 16), plainHeader);
  });

  testWidgets('a key that is not 64 hex characters is refused before SQLite', (
    tester,
  ) async {
    expect(
      () => openEncrypted(path, "abc' OR 1=1 --"),
      throwsA(isA<DatabaseKeyUnavailable>()),
    );
    // Nothing was created.
    expect(File(path).existsSync(), isFalse);
  });
}
