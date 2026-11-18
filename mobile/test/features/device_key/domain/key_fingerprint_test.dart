// The fingerprint must be exactly the server's: lower-case hex SHA-256 of
// the 91 SPKI bytes (signing spec, section 2). Checked against the shared
// test vectors in docs/signing-vectors.json.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/device_key/domain/key_fingerprint.dart';

void main() {
  // `flutter test` runs with mobile/ as the working directory.
  final vectors = jsonDecode(
    File('../docs/signing-vectors.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final positive = vectors['positive']! as List<Object?>;
  final registration = positive.first! as Map<String, Object?>;
  final vectorKey = base64.decode(registration['publicKey']! as String);

  test('the vector key is the 91-byte SPKI the spec describes', () {
    expect(registration['name'], 'registration');
    expect(vectorKey, hasLength(91));
  });

  test('matches the fingerprint computed independently with Node', () {
    // Worked out on the laptop with Node's own crypto, the same call the
    // backend makes (signatureService.spkiFingerprint):
    //   createHash('sha256').update(<the 91 bytes>).digest('hex')
    // so this compares two implementations, not the code with itself.
    expect(
      keyFingerprint(Uint8List.fromList(vectorKey)),
      '4d61912d42cfc3d967e27e9179e01054cf7ef9d333a87b414a5ac153f4c93d53',
    );
  });

  test('64 lower-case hex characters', () {
    final fingerprint = keyFingerprint(Uint8List.fromList(vectorKey));
    expect(fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('every vector uses the same key, so one fingerprint covers them', () {
    for (final vector in positive) {
      expect((vector! as Map)['publicKey'], registration['publicKey']);
    }
  });

  test('shortFingerprint is the first 8 characters', () {
    expect(
      shortFingerprint(
        '4d61912d42cfc3d967e27e9179e01054cf7ef9d333a87b414a5ac153f4c93d53',
      ),
      '4d61912d',
    );
    expect(shortFingerprint('abc'), 'abc');
  });
}
