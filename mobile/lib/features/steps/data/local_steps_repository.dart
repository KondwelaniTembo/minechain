// The phone's saved custody steps (plan M3 and §2), on the local database.
//
// Every query uses `?` parameters; no value is ever joined into SQL text.
// Rows are never deleted: not by logout, not by sync, not by any outcome.
// A rejected step is signed evidence and stays.
//
// The work functions below are top-level, not methods, on purpose: they are
// sent to the database's background isolate, and a closure that used `this`
// would try to send the whole repository with it.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../core/database/local_database.dart';
import '../domain/local_step.dart';

/// Saving a step failed because a step with this `step_id` is already
/// saved. Every step gets a fresh id, so this means a bug (or a double tap
/// handled twice).
final class LocalStepConflict implements Exception {
  const LocalStepConflict();

  @override
  String toString() => 'LocalStepConflict()';
}

/// SQLite refused something else. [operation] says what; the SQLite text is
/// dropped, because it can repeat the statement's values (a payload).
final class LocalStepsFailure implements Exception {
  const LocalStepsFailure(this.operation);
  final String operation;

  @override
  String toString() => 'LocalStepsFailure($operation)';
}

class LocalStepsRepository {
  LocalStepsRepository(this._db);

  final LocalDatabase _db;

  /// The most steps sent in one sync request (api.md: 1 to 50).
  static const int batchSize = 50;

  /// Saves [step] as `queued`. Returns once the row is committed: only then
  /// may the screen say "Saved on this phone" (plan §3).
  ///
  /// Throws [LocalStepConflict] or [LocalStepsFailure].
  Future<void> insert(NewLocalStep step) => _db.run((db) => _insert(db, step));

  /// [actorId]'s steps, newest first (the "My consignments" list).
  Future<List<LocalStep>> listForActor(String actorId) =>
      _db.run((db) => _listForActor(db, actorId));

  /// The next steps to send for [actorId], oldest first, at most
  /// [batchSize]: those `queued`, and those `deferred` whose wait is over at
  /// [now]. With [ignoreBackoff] (the user tapped Send), every deferred one.
  /// With [after], only steps later in the send order than that place.
  Future<List<LocalStep>> dueForSync({
    required String actorId,
    required DateTime now,
    bool ignoreBackoff = false,
    SyncCursor? after,
  }) {
    // Plain values only: this closure goes to the database's isolate.
    final afterTime = after == null ? null : storedTime(after.createdAt);
    final afterId = after?.stepId;
    return _db.run(
      (db) => _dueForSync(
        db,
        actorId,
        storedTime(now),
        ignoreBackoff,
        afterTime,
        afterId,
      ),
    );
  }

  /// How many steps [dueForSync] would offer in all (no batch limit, no
  /// cursor), for "Sending 3 of 7".
  Future<int> countDue({
    required String actorId,
    required DateTime now,
    bool ignoreBackoff = false,
  }) => _db.run((db) => _countDue(db, actorId, storedTime(now), ignoreBackoff));

  /// [actorId]'s steps counted by what the server said, at [now].
  Future<StepCounts> countsForActor(String actorId, {required DateTime now}) {
    final stuckSince = storedTime(now.subtract(StepCounts.stuckAfter));
    return _db.run((db) => _countsForActor(db, actorId, stuckSince));
  }

  /// When [qrCode] was first registered on this phone, by ANY account, or
  /// null if never (the duplicate check, plan §6). A registration the server
  /// rejected does not count: it was never stored there, so registering the
  /// record again is the right thing to do.
  Future<DateTime?> registeredOn(String qrCode) =>
      _db.run((db) => _registeredOn(db, qrCode));

  /// Writes down the server's answers, all in one transaction. Only rows
  /// still `queued` or `deferred` change: an answer never moves a synced,
  /// flagged or rejected step back. Returns how many rows changed.
  Future<int> applyResults(
    List<StepSyncUpdate> updates, {
    required DateTime at,
  }) => _db.run((db) => _applyResults(db, updates, storedTime(at)));
}

final localStepsRepositoryProvider = FutureProvider<LocalStepsRepository>((
  ref,
) async {
  return LocalStepsRepository(await ref.watch(localDatabaseProvider.future));
});

// ---- The work, run on the database's isolate --------------------------------

/// SQLite's extended code for a PRIMARY KEY clash (SQLITE_CONSTRAINT_PRIMARYKEY).
const int _primaryKeyClash = 1555;

void _insert(Database db, NewLocalStep step) {
  try {
    db.execute(
      '''
      INSERT INTO local_steps (
        step_id, actor_id, type, qr_code, mineral, weight_mg, latitude,
        longitude, captured_at, payload, signature, key_fingerprint,
        gps_accuracy_m, sync_state, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?)
      ''',
      [
        step.stepId,
        step.actorId,
        step.type,
        step.qrCode,
        step.mineral,
        step.weightMg,
        step.latitude,
        step.longitude,
        step.capturedAt,
        step.payload,
        step.signature,
        step.keyFingerprint,
        step.gpsAccuracyM,
        storedTime(step.createdAt),
      ],
    );
  } on SqliteException catch (e) {
    if (e.extendedResultCode == _primaryKeyClash) {
      throw const LocalStepConflict();
    }
    throw const LocalStepsFailure('insert');
  }
}

List<LocalStep> _listForActor(Database db, String actorId) {
  try {
    return db
        .select(
          'SELECT * FROM local_steps WHERE actor_id = ? '
          'ORDER BY created_at DESC, step_id DESC',
          [actorId],
        )
        .map(LocalStep.fromRow)
        .toList();
  } on SqliteException {
    throw const LocalStepsFailure('list');
  }
}

DateTime? _registeredOn(Database db, String qrCode) {
  try {
    final rows = db.select(
      "SELECT min(created_at) AS first FROM local_steps "
      "WHERE qr_code = ? AND type = 'registration' "
      "AND sync_state <> 'rejected'",
      [qrCode],
    );
    final first = rows.single['first'] as String?;
    return first == null ? null : DateTime.parse(first);
  } on SqliteException {
    throw const LocalStepsFailure('registered-on');
  }
}

/// The rows a sync may send: queued, or deferred with the wait over (or
/// ignored). Shared by [_dueForSync] and [_countDue], so the two never
/// disagree. Its three `?` take: actor, ignoreBackoff (1 or 0), now.
const String _dueWhere = '''
  actor_id = ?
  AND (sync_state = 'queued'
       OR (sync_state = 'deferred'
           AND (? = 1 OR next_attempt_at IS NULL OR next_attempt_at <= ?)))
''';

List<LocalStep> _dueForSync(
  Database db,
  String actorId,
  String now,
  bool ignoreBackoff,
  String? afterTime,
  String? afterId,
) {
  try {
    return db
        .select(
          '''
          SELECT * FROM local_steps
          WHERE $_dueWhere
            AND (? IS NULL OR created_at > ?
                 OR (created_at = ? AND step_id > ?))
          ORDER BY created_at ASC, step_id ASC
          LIMIT ?
          ''',
          [
            actorId,
            ignoreBackoff ? 1 : 0,
            now,
            afterTime,
            afterTime,
            afterTime,
            afterId,
            LocalStepsRepository.batchSize,
          ],
        )
        .map(LocalStep.fromRow)
        .toList();
  } on SqliteException {
    throw const LocalStepsFailure('due');
  }
}

int _countDue(Database db, String actorId, String now, bool ignoreBackoff) {
  try {
    final rows = db.select(
      'SELECT count(*) AS n FROM local_steps WHERE $_dueWhere',
      [actorId, ignoreBackoff ? 1 : 0, now],
    );
    return rows.single['n'] as int;
  } on SqliteException {
    throw const LocalStepsFailure('count-due');
  }
}

StepCounts _countsForActor(Database db, String actorId, String stuckSince) {
  try {
    // total() rather than sum(): it gives 0, not NULL, when there are no
    // rows, and a REAL, read back with toInt().
    final row = db.select(
      '''
      SELECT
        total(sync_state IN ('queued', 'deferred')) AS waiting,
        total(sync_state IN ('synced', 'flagged')) AS sent_to_server,
        total(sync_state = 'flagged'
              OR (sync_state = 'synced' AND review_status = 'flagged'))
          AS under_review,
        total(sync_state = 'rejected') AS rejected,
        total(sync_state = 'deferred' AND first_deferred_at <= ?) AS stuck
      FROM local_steps
      WHERE actor_id = ?
      ''',
      [stuckSince, actorId],
    ).single;
    int n(String column) => (row[column] as num).toInt();
    return StepCounts(
      waiting: n('waiting'),
      sentToServer: n('sent_to_server'),
      underReview: n('under_review'),
      rejected: n('rejected'),
      stuck: n('stuck'),
    );
  } on SqliteException {
    throw const LocalStepsFailure('counts');
  }
}

int _applyResults(Database db, List<StepSyncUpdate> updates, String at) {
  // Only an unanswered step may change.
  const open = "sync_state IN ('queued', 'deferred')";
  var changed = 0;
  try {
    db.execute('BEGIN IMMEDIATE');
    for (final update in updates) {
      switch (update) {
        case StepSynced(
          :final stepId,
          :final reviewStatus,
          :final transactionId,
        ):
          db.execute(
            "UPDATE local_steps SET sync_state = 'synced', review_status = ?, "
            'server_transaction_id = ?, last_code = NULL, last_message = NULL, '
            'next_attempt_at = NULL, synced_at = ? '
            'WHERE step_id = ? AND $open',
            [reviewStatus, transactionId, at, stepId],
          );
        case StepFlagged(
          :final stepId,
          :final code,
          :final message,
          :final reviewStatus,
          :final transactionId,
        ):
          db.execute(
            "UPDATE local_steps SET sync_state = 'flagged', review_status = ?, "
            'server_transaction_id = ?, last_code = ?, last_message = ?, '
            'next_attempt_at = NULL, synced_at = ? '
            'WHERE step_id = ? AND $open',
            [reviewStatus, transactionId, code, message, at, stepId],
          );
        case StepRejected(:final stepId, :final code, :final message):
          db.execute(
            "UPDATE local_steps SET sync_state = 'rejected', last_code = ?, "
            'last_message = ?, next_attempt_at = NULL '
            'WHERE step_id = ? AND $open',
            [code, message, stepId],
          );
        case StepDeferred(
          :final stepId,
          :final code,
          :final message,
          :final nextAttemptAt,
        ):
          db.execute(
            "UPDATE local_steps SET sync_state = 'deferred', last_code = ?, "
            'last_message = ?, attempts = attempts + 1, '
            'first_deferred_at = COALESCE(first_deferred_at, ?), '
            'next_attempt_at = ? '
            'WHERE step_id = ? AND $open',
            [code, message, at, storedTime(nextAttemptAt), stepId],
          );
      }
      changed += db.updatedRows;
    }
    db.execute('COMMIT');
    return changed;
  } on SqliteException {
    try {
      db.execute('ROLLBACK');
    } on SqliteException {
      // Nothing more to undo.
    }
    throw const LocalStepsFailure('apply');
  }
}
