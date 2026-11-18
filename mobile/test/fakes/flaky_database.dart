// A LocalDatabase that fails chosen calls, for the "phone was busy" tests.
//
// It wraps a real (in-memory) database. A call it is told to fail throws the
// given error instead of running, as the real EncryptedLocalDatabase does
// when opening the file fails (DatabaseBusy, DatabaseWrongKey) or as the
// repository does when a query fails (LocalStepsFailure). Nothing is run, so
// nothing in the rows changes.

import 'package:minechain/core/database/local_database.dart';
import 'package:sqlite3/sqlite3.dart';

class FlakyLocalDatabase implements LocalDatabase {
  FlakyLocalDatabase(this._inner);

  final LocalDatabase _inner;

  /// Calls made so far, counting the failed ones.
  int calls = 0;

  /// Call number (from 1) → the error that call throws.
  final Map<int, Object> failAt = {};

  /// The next call throws [error].
  void failNext(Object error) => failAt[calls + 1] = error;

  @override
  Future<T> run<T>(T Function(Database db) work) async {
    calls++;
    final error = failAt.remove(calls);
    if (error != null) throw error;
    return _inner.run(work);
  }
}
