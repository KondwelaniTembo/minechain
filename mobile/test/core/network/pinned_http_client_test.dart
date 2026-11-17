// The pinned TLS setup, with no network: the bundled roots load, build a
// TLS 1.3-only context, and are the files that were verified; bad input fails
// loudly.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/network/pinned_http_client.dart';
import 'package:minechain/core/network/pinned_roots.dart';

/// Verified with Windows certutil on 16 Nov 2026 01:28 against the CAs'
/// published values (assets/certs/README.md). Written out here on purpose,
/// not shared with the app, so swapping a file AND a constant in lib/ is not
/// enough to make this pass.
const verifiedFingerprints = [
  // gts_root_r4.pem
  '349dfa4058c5e263123b398ae795573c4e1313c83fe68f93556cd5e8031b3c7d',
  // globalsign_ecc_root_r4.pem
  'b085d70b964f191a73e4af0d54ae7a0e07aafdaf9b71dd0862138ab7325a24a2',
  // isrg_root_x1.pem
  '96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6',
];

/// An asset bundle with nothing in it, or with every file empty.
class _FakeBundle extends AssetBundle {
  _FakeBundle({required this.empty});
  final bool empty;

  @override
  Future<ByteData> load(String key) async {
    if (empty) return ByteData(0);
    // What rootBundle does for a key that is not in the app.
    throw Exception('Unable to load asset: $key');
  }

  @override
  Future<T> loadStructuredData<T>(
    String key,
    Future<T> Function(String value) parser,
  ) => throw UnimplementedError();
}

void main() {
  // rootBundle needs Flutter's test binding to be running.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the bundled roots', () {
    test('all three load and none is empty', () async {
      final roots = await loadPinnedRoots();
      expect(roots, hasLength(pinnedRootFiles.length));
      for (final root in roots) {
        expect(root, isNotEmpty);
      }
    });

    test('build a context without error, with TLS 1.3 as the minimum',
        () async {
      final context = buildPinnedContext(await loadPinnedRoots());
      expect(context.minimumTlsProtocolVersion, TlsProtocolVersion.tls1_3);
    });

    test('are exactly the certificates verified with certutil', () async {
      final roots = await loadPinnedRoots();
      for (var i = 0; i < roots.length; i++) {
        expect(
          sha256.convert(derOfPem(roots[i])).toString(),
          verifiedFingerprints[i],
          reason: '${pinnedRootFiles[i]} is not the verified certificate',
        );
      }
    });

    test('the HTTP client gets the plan\'s timeouts', () async {
      final client = buildPinnedHttpClient(
        buildPinnedContext(await loadPinnedRoots()),
      );
      addTearDown(client.close);
      expect(client.connectionTimeout, const Duration(seconds: 15));
      expect(client.idleTimeout, const Duration(seconds: 15));
    });
  });

  group('bad input fails loudly', () {
    test('an empty list', () {
      expect(() => buildPinnedContext([]), throwsA(isA<PinningSetupError>()));
    });

    test('an empty file', () {
      expect(
        () => buildPinnedContext([Uint8List(0)]),
        throwsA(isA<PinningSetupError>()),
      );
    });

    test('bytes that are not PEM at all', () {
      expect(
        () => buildPinnedContext([utf8.encode('not a certificate')]),
        throwsA(isA<PinningSetupError>()),
      );
    });

    test('PEM markers around garbage', () {
      // Gets past our own PEM check, so this checks that the TLS library
      // itself refuses it, and that we turn its refusal into our error.
      final fake = utf8.encode(
        '-----BEGIN CERTIFICATE-----\n'
        'Tm90IGEgcmVhbCBjZXJ0aWZpY2F0ZQ==\n'
        '-----END CERTIFICATE-----\n',
      );
      expect(() => buildPinnedContext([fake]), throwsA(isA<PinningSetupError>()));
    });

    test('one good root and one bad: refused, not quietly reduced to one',
        () async {
      final good = (await loadPinnedRoots()).first;
      expect(
        () => buildPinnedContext([good, utf8.encode('garbage')]),
        throwsA(isA<PinningSetupError>()),
      );
    });

    test('a root missing from the app', () {
      expect(
        loadPinnedRoots(bundle: _FakeBundle(empty: false)),
        throwsA(isA<PinningSetupError>()),
      );
    });

    test('a root packed as an empty file', () {
      expect(
        loadPinnedRoots(bundle: _FakeBundle(empty: true)),
        throwsA(isA<PinningSetupError>()),
      );
    });
  });
}
