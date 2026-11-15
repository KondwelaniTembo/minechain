// Loads the three pinned root certificates that are packed inside the app.
//
// Flutter's "asset bundle" is the set of files listed under `assets:` in
// pubspec.yaml, built into the APK. rootBundle reads them at run time.

import 'package:flutter/services.dart';

import 'pinned_http_client.dart';

/// The bytes of each pinned root, in the order of [pinnedRootFiles].
///
/// Throws [PinningSetupError] if any file is missing from the app or empty.
/// There is no fallback to the phone's own certificates: without our roots
/// the app makes no connections at all (fail closed).
///
/// [bundle] is only for tests; the app uses rootBundle.
Future<List<Uint8List>> loadPinnedRoots({AssetBundle? bundle}) async {
  final assets = bundle ?? rootBundle;
  final roots = <Uint8List>[];

  for (final path in pinnedRootFiles) {
    final ByteData data;
    try {
      data = await assets.load(path);
    } catch (_) {
      throw PinningSetupError('$path is missing from the app');
    }
    // ByteData is a view onto memory; this copies out exactly its bytes.
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (bytes.isEmpty) throw PinningSetupError('$path is empty');
    roots.add(bytes);
  }

  return roots;
}
