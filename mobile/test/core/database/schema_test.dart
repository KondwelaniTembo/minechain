// Schema version 1 (plan §2) and migrations, on an in-memory database on the
// laptop. No encryption here: that is proved on the phone
// (integration_test/db_encryption_test.dart).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/database/database_failure.dart';
import 'package:minechain/core/database/schema.dart';
import 'package:sqlite3/sqlite3.dart';

/// A row that passes every CHECK; tests change one value at a time.
Map<String, Object?> validRow() => {
  'step_id': '6f1d2c3a-0000-4000-8000-000000000101',
  'actor_id': '3f2b6c1e-0000-4000-8000-000000000101',
  'type': 'registration',
  'qr_code': 'MC-DEMO-000001',
  'mineral': 'gold',
  'weight_mg': '1500000',
  'latitude': '-15.419012',
  'longitude': '28.288105',
  'captured_at': '2026-11-10T08:00:00.000Z',
  'payload': 'minechain-step/1/registration\n',
  'signature': 'MEQCIF==',
  'key_fingerprint': '4d61912d',
  'created_at': '2026-11-10T08:00:00.000Z',
};

void insertRow(Database db, Map<String, Object?> row) {
  final columns = row.keys.join(', ');
  final marks = List.filled(row.length, '?').join(', ');
  db.execute(
    'INSERT INTO local_steps ($columns) VALUES ($marks)',
    row.values.toList(),
  );
}

void main() {
  late Database db;

  setUp(() => db = sqlite3.openInMemory());
  tearDown(() => db.close());

  group('migrate', () {
    test('a new file goes to version 1 with both tables', () {
      expect(db.userVersion, 0);
      migrate(db);

      expect(db.userVersion, 1);
      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((r) => r['name'])
          .toSet();
      expect(tables, containsAll(['local_steps', 'settings']));
    });

    test('creates the two indexes', () {
      migrate(db);
      final indexes = db
          .select("SELECT name FROM sqlite_master WHERE type = 'index'")
          .map((r) => r['name'])
          .toSet();
      expect(
        indexes,
        containsAll(['local_steps_actor_created', 'local_steps_qr_type']),
      );
    });

    test('running it again changes nothing', () {
      migrate(db);
      insertRow(db, validRow());
      migrate(db);
      expect(db.userVersion, 1);
      expect(db.select('SELECT * FROM local_steps'), hasLength(1));
    });

    test('a file from a newer app is refused, untouched', () {
      db.userVersion = 7;
      expect(() => migrate(db), throwsA(isA<DatabaseTooNew>()));
      expect(db.userVersion, 7);
      expect(db.select('SELECT name FROM sqlite_master'), isEmpty);
    });
  });

  group('local_steps rules', () {
    setUp(() => migrate(db));

    test('a valid row is accepted, queued by default', () {
      insertRow(db, validRow());
      final row = db
          .select('SELECT sync_state, attempts FROM local_steps')
          .single;
      expect(row['sync_state'], 'queued');
      expect(row['attempts'], 0);
    });

    for (final (name, column, value) in <(String, String, Object?)>[
      ('an unknown sync state', 'sync_state', 'sending'),
      ('an unknown type', 'type', 'export'),
      (
        'an upper-case step id',
        'step_id',
        '6F1D2C3A-0000-4000-8000-000000000101',
      ),
      ('a short step id', 'step_id', 'abc'),
      ('a negative attempt count', 'attempts', -1),
      // STRICT refuses only what cannot be converted without loss
      // (sqlite.org/stricttables.html): text that is not a number into an
      // INTEGER column, and a BLOB, which never converts, into a TEXT one.
      ('text in the attempt count (STRICT)', 'attempts', 'many'),
      (
        'a BLOB as the weight (STRICT)',
        'weight_mg',
        Uint8List.fromList([1, 2]),
      ),
      ('a missing payload', 'payload', null),
    ]) {
      test('refuses $name', () {
        expect(
          () => insertRow(db, validRow()..[column] = value),
          throwsA(isA<SqliteException>()),
        );
      });
    }

    test('a weight given as a number is stored as TEXT', () {
      // STRICT does not refuse this: an integer converts to text without
      // loss, so SQLite stores '1500000'. What the test proves is that the
      // column keeps text, whatever it is handed, so a weight never comes
      // back as a number.
      insertRow(db, validRow()..['weight_mg'] = 1500000);

      final row = db
          .select(
            'SELECT weight_mg, typeof(weight_mg) AS kind FROM local_steps',
          )
          .single;
      expect(row['kind'], 'text');
      expect(row['weight_mg'], '1500000');
    });

    test('a registration must name its mineral', () {
      expect(
        () => insertRow(db, validRow()..['mineral'] = null),
        throwsA(isA<SqliteException>()),
      );
    });

    test('a handoff must not name a mineral', () {
      expect(
        () => insertRow(
          db,
          validRow()
            ..['type'] = 'handoff'
            ..['mineral'] = 'gold',
        ),
        throwsA(isA<SqliteException>()),
      );
      insertRow(
        db,
        validRow()
          ..['type'] = 'handoff'
          ..['mineral'] = null,
      );
    });

    test('a step id is saved only once', () {
      insertRow(db, validRow());
      expect(() => insertRow(db, validRow()), throwsA(isA<SqliteException>()));
    });
  });
}
