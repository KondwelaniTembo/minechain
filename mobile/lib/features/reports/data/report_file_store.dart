// Where a downloaded report is kept (reports plan, T1, Q5): one folder,
// `reports/`, inside the app's private cache, holding at most one file.
//
// Private: no other app can read the folder, and no storage permission is
// needed. Android may empty a cache when space runs out, which is fine: the
// file is only kept so "Share again" works and a slow receiving app (Gmail
// attaches after a pause) still finds it. Every earlier report is deleted
// before a new one is written, so a report holding people's usernames and
// places does not pile up on the phone.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/saved_report.dart';

/// The file could not be written (the phone is full, or the folder is
/// gone). Carries no path or name.
class ReportNotSaved implements Exception {
  const ReportNotSaved();

  @override
  String toString() => 'ReportNotSaved()';
}

class ReportFileStore {
  ReportFileStore({required this._cacheDirectory});

  /// The app's cache folder; injected so tests use a temporary one.
  final Future<Directory> Function() _cacheDirectory;

  /// Writes [bytes] unchanged as [filename], after deleting every earlier
  /// report. Returns the file's path. Throws [ReportNotSaved].
  Future<String> save(Uint8List bytes, String filename) async {
    // Checked here too, not only by whoever chose the name: this is where a
    // bad name would do harm.
    if (!isSafeReportFilename(filename)) {
      throw ArgumentError('Not a safe report filename');
    }
    try {
      final folder = Directory(
        '${(await _cacheDirectory()).path}${Platform.pathSeparator}reports',
      );
      if (await folder.exists()) {
        await for (final entry in folder.list(followLinks: false)) {
          await entry.delete(recursive: true);
        }
      } else {
        await folder.create(recursive: true);
      }
      final file = File('${folder.path}${Platform.pathSeparator}$filename');
      // The bytes as received: the BOM stays, so Excel reads the letters
      // right; CRLF stays, as RFC 4180 says.
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } on FileSystemException {
      throw const ReportNotSaved();
    }
  }
}

final reportFileStoreProvider = Provider<ReportFileStore>((ref) {
  return ReportFileStore(cacheDirectory: getTemporaryDirectory);
});
