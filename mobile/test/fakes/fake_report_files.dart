// TEST ONLY: stand-ins for the phone's side of a report (reports plan, T2
// and T3): the file store and the share sheet.
//
// Widget tests run on a fake clock, where real file writes never finish, so
// the store only records what it was given. The real store is tested on a
// temporary folder in reports_repository_test.dart.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:minechain/features/reports/data/report_file_store.dart';
import 'package:minechain/features/reports/data/report_sharer.dart';
import 'package:minechain/features/reports/domain/saved_report.dart';

class FakeReportFileStore implements ReportFileStore {
  /// Every file saved, by name, with its bytes.
  final List<(String, Uint8List)> saved = [];

  /// When true, save() fails as a full phone would.
  bool full = false;

  @override
  Future<String> save(Uint8List bytes, String filename) async {
    if (full) throw const ReportNotSaved();
    saved.add((filename, bytes));
    return '/cache/reports/$filename';
  }
}

class FakeReportSharer implements ReportSharer {
  /// Every report handed to the share sheet, in order.
  final List<SavedReport> shared = [];

  /// What the next share answers.
  ShareOutcome outcome = ShareOutcome.shared;

  /// When set, share() throws it instead.
  Exception? error;

  /// While set and not completed, the share sheet stays "open".
  Completer<void>? hold;

  @override
  Future<ShareOutcome> share(SavedReport report) async {
    shared.add(report);
    final waiting = hold;
    if (waiting != null) await waiting.future;
    final failure = error;
    if (failure != null) throw failure;
    return outcome;
  }
}

/// Overrides that put [store] and [sharer] in place.
List<Override> reportFileOverrides(
  FakeReportFileStore store,
  FakeReportSharer sharer,
) => [
  reportFileStoreProvider.overrideWithValue(store),
  reportSharerProvider.overrideWithValue(sharer),
];
