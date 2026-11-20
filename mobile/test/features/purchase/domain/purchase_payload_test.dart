// The purchase payload against docs/signing-vectors.json, byte for byte.
// The file is only read here, never regenerated. The spec has no written
// purchase example; the positive vector is the reference.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/handoff/domain/handoff_payload.dart';
import 'package:minechain/features/purchase/domain/purchase_payload.dart';

// `flutter test` runs with mobile/ as the working directory.
final Map<String, Object?> vectors = jsonDecode(
  File('../docs/signing-vectors.json').readAsStringSync(),
) as Map<String, Object?>;

List<Map<String, Object?>> listOf(String key) =>
    (vectors[key]! as List).cast<Map<String, Object?>>();

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// A payload's `key=value` lines as a map (no header).
Map<String, String> fieldsOf(String payload) => {
  for (final line in payload.split('\n').skip(1).where((l) => l.isNotEmpty))
    line.substring(0, line.indexOf('=')): line.substring(line.indexOf('=') + 1),
};

String purchaseFrom(Map<String, String> f) => buildPurchasePayload(
  stepId: f['step_id']!,
  actorId: f['actor_id']!,
  qrCode: f['qr_code']!,
  weightMg: f['weight_mg']!,
  latitude: f['latitude']!,
  longitude: f['longitude']!,
  capturedAt: f['captured_at']!,
);

String handoffFrom(Map<String, String> f) => buildHandoffPayload(
  stepId: f['step_id']!,
  actorId: f['actor_id']!,
  qrCode: f['qr_code']!,
  weightMg: f['weight_mg']!,
  latitude: f['latitude']!,
  longitude: f['longitude']!,
  capturedAt: f['captured_at']!,
);

void main() {
  group('the positive purchase vector', () {
    final vector = listOf('positive')
        .singleWhere((v) => v['name'] == 'purchase');
    final fields = vector['fields']! as Map<String, Object?>;

    String build() => buildPurchasePayload(
      stepId: fields['stepId']! as String,
      actorId: fields['actorId']! as String,
      qrCode: fields['qrCode']! as String,
      weightMg: fields['weightMg']! as String,
      latitude: fields['latitude']! as String,
      longitude: fields['longitude']! as String,
      capturedAt: fields['capturedAt']! as String,
    );

    test('is a purchase, with no mineral among its fields', () {
      expect(fields['type'], 'purchase');
      expect(fields.containsKey('mineral'), isFalse);
    });

    test('the same text', () {
      expect(build(), vector['payload']);
    });

    test('the same bytes', () {
      expect(hex(utf8.encode(build())), vector['payloadHex']);
    });

    test('the same SHA-256', () {
      expect(
        sha256.convert(utf8.encode(build())).toString(),
        vector['payloadSha256'],
      );
    });

    test('eight lines under the purchase header, no mineral line', () {
      final text = build();
      expect(text, startsWith('minechain-step/1/purchase\n'));
      expect('\n'.allMatches(text), hasLength(8));
      expect(text.endsWith('\n'), isTrue);
      expect(text.contains('\r'), isFalse);
      expect(text, isNot(contains('mineral=')));
    });
  });

  group('"handoff signature under a purchase header"', () {
    // The vector's TEXT is a well-formed purchase (its signature is a
    // handoff's, which is why it must not verify). So the same fields
    // built as a purchase give exactly that text, and as a handoff do not.
    final bad = listOf('negativeSignatures').singleWhere(
      (v) => v['name'] == 'handoff signature under a purchase header',
    );
    final payload = bad['payload']! as String;

    test('a purchase built from its fields is its text', () {
      expect(purchaseFrom(fieldsOf(payload)), payload);
    });

    test('the handoff from the same fields differs only in the header', () {
      final handoff = handoffFrom(fieldsOf(payload));
      expect(handoff, isNot(payload));
      expect(
        handoff.replaceFirst(
          'minechain-step/1/handoff\n',
          'minechain-step/1/purchase\n',
        ),
        payload,
      );
    });
  });

  group('every field is checked, as for a handoff', () {
    String buildWith({
      String qrCode = 'MC-DEMO-000001',
      String weightMg = '1494500',
      String capturedAt = '2026-11-11T09:15:00.000Z',
    }) => buildPurchasePayload(
      stepId: '6f1d2c3a-0000-4000-8000-000000000103',
      actorId: '3f2b6c1e-0000-4000-8000-000000000103',
      qrCode: qrCode,
      weightMg: weightMg,
      latitude: '-15.419300',
      longitude: '28.287800',
      capturedAt: capturedAt,
    );

    test('the default values are valid', () {
      expect(buildWith(), startsWith('minechain-step/1/purchase\n'));
    });

    for (final (field, call) in <(String, String Function())>[
      ('qr_code', () => buildWith(qrCode: 'MC 1')),
      ('weight_mg', () => buildWith(weightMg: '0')),
      ('captured_at', () => buildWith(capturedAt: '2026-11-11T09:15:00Z')),
    ]) {
      test('$field is refused, naming the field only', () {
        expect(
          call,
          throwsA(
            isA<PayloadFieldInvalid>()
                .having((e) => e.field, 'field', field)
                .having((e) => e.toString(), 'text', isNot(contains('MC 1'))),
          ),
        );
      });
    }
  });
}
