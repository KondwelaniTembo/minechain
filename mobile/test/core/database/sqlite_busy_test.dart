// "Busy" told apart from every other SQLite refusal, on real SQLite: two
// connections to one file in a temporary folder, the first holding an
// exclusive lock, the second (no busy timeout) refused at once. Plain
// (unencrypted) SQLite: the lock rules are the same with the cipher, and
// the cipher is proved on the phone (integration_test/db_encryption_test).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/database/database_failure.dart';
import 'package:minechain/core/database/local_database.dart';
import 'package:minechain/core/database/schema.dart';
import 'package:minechain/core/database/sqlite_busy.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:sqlite3/sqlite3.dart';

/// Runs work on one given connection, on this isolate.
class _OneConnection implements LocalDatabase {
  _OneConnection(this.db);
  final Database db;

  @override
  Future<T> run<T>(T Function(Database db) work) async => work(db);
}

void main() {
  late Directory folder;
  late String path;
  late Database holder;
  late Database other;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('minechain_busy_');
    path = '${folder.path}${Platform.pathSeparator}busy.db';
    final setup = sqlite3.open(path);
    migrate(setup);
    setup.close();
    holder = sqlite3.open(path);
    other = sqlite3.open(path); // busy_timeout 0: refused straight away
  });

  tearDown(() {
    other.close();
    holder.close();
    folder.deleteSync(recursive: true);
  });

  void lockTheFile() => holder.execute('BEGIN EXCLUSIVE');

  test('a locked file is busy; another refusal is not', () {
    lockTheFile();
    late SqliteException busy;
    try {
      other.select('SELECT count(*) FROM local_steps');
    } on SqliteException catch (e) {
      busy = e;
    }
    expect(isBusyOrLocked(busy), isTrue);

    holder.execute('ROLLBACK');
    late SqliteException missing;
    try {
      other.select('SELECT * FROM no_such_table');
    } on SqliteException catch (e) {
      missing = e;
    }
    expect(isBusyOrLocked(missing), isFalse);
  });

  test('the repository marks a busy query, and only a busy one', () async {
    final steps = LocalStepsRepository(_OneConnection(other));
    final now = DateTime.utc(2026, 11, 16, 9);

    lockTheFile();
    await expectLater(
      steps.countDue(actorId: 'a', now: now),
      throwsA(
        isA<LocalStepsFailure>()
            .having((f) => f.operation, 'operation', 'count-due')
            .having((f) => f.busy, 'busy', isTrue),
      ),
    );
    holder.execute('ROLLBACK');

    // A file without the tables: refused, but not busy.
    final emptyPath = '${folder.path}${Platform.pathSeparator}empty.db';
    final empty = sqlite3.open(emptyPath);
    addTearDown(empty.close);
    await expectLater(
      LocalStepsRepository(_OneConnection(empty))
          .countDue(actorId: 'a', now: now),
      throwsA(isA<LocalStepsFailure>().having((f) => f.busy, 'busy', isFalse)),
    );
  });

  test('opening while locked is DatabaseBusy, not a broken file', () {
    lockTheFile();
    expect(
      () => migrate(other),
      throwsA(
        isA<DatabaseBusy>().having((f) => f.stage, 'stage', 'read-version'),
      ),
    );
  });

  test('only a real open failure counts as "cannot be opened"', () {
    for (final failure in const <DatabaseFailure>[
      DatabaseKeyUnavailable(),
      DatabaseKeyMissing(),
      DatabaseCipherUnavailable(),
      DatabaseWrongKey(),
      DatabaseTooNew(9),
      DatabaseOpenFailed('setup'),
    ]) {
      expect(savedWorkUnreadable(failure), isTrue, reason: '$failure');
    }
    expect(savedWorkUnreadable(const DatabaseBusy('key-check')), isFalse);
    expect(
      savedWorkUnreadable(const LocalStepsFailure('due', busy: true)),
      isFalse,
    );
    expect(savedWorkUnreadable(const LocalStepsFailure('due')), isFalse);
    expect(savedWorkUnreadable(StateError('x')), isFalse);
  });
}
