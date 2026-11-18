// The registration payload against docs/signing-vectors.json, byte for byte:
// the positive vector is built exactly, and no negative vector can ever be
// produced.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/registration/domain/registration_payload.dart';

// `flutter test` runs with mobile/ as the working directory.
final Map<String, Object?> vectors = jsonDecode(
  File('../docs/signing-vectors.json').readAsStringSync(),
) as Map<String, Object?>;

List<Map<String, Object?>> listOf(String key) =>
    (vectors[key]! as List).cast<Map<String, Object?>>();

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// A negative vector's payload taken apart into its `key=value` lines, the
/// way a careless parser would: split on LF, drop CRs. The header is kept
/// under the key `header`.
Map<String, String> looseFields(String payload) {
  final lines = payload.split('\n').map((l) => l.replaceAll('\r', ''));
  final fields = <String, String>{};
  for (final line in lines) {
    if (line.isEmpty) continue;
    final at = line.indexOf('=');
    if (at < 0) {
      fields['header'] = line;
    } else {
      fields[line.substring(0, at)] = line.substring(at + 1);
    }
  }
  return fields;
}

void main() {
  group('the positive registration vector', () {
    final vector = listOf('positive')
        .singleWhere((v) => v['name'] == 'registration');
    final fields = vector['fields']! as Map<String, Object?>;

    String build() => buildRegistrationPayload(
      stepId: fields['stepId']! as String,
      actorId: fields['actorId']! as String,
      qrCode: fields['qrCode']! as String,
      mineral: Mineral.fromApiName(fields['mineral']! as String)!,
      weightMg: fields['weightMg']! as String,
      latitude: fields['latitude']! as String,
      longitude: fields['longitude']! as String,
      capturedAt: fields['capturedAt']! as String,
    );

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

    test('nine lines, each ending with LF, the last included', () {
      final text = build();
      expect(text.endsWith('\n'), isTrue);
      expect('\n'.allMatches(text), hasLength(9));
      expect(text.contains('\r'), isFalse);
    });
  });

  group('no negative vector can be produced', () {
    for (final vector in listOf('negativePayloads')) {
      final name = vector['name']! as String;
      final bad = vector['payload']! as String;

      test(name, () {
        final f = looseFields(bad);
        String? built;
        try {
          built = buildRegistrationPayload(
            stepId: f['step_id'] ?? '',
            actorId: f['actor_id'] ?? '',
            qrCode: f['qr_code'] ?? '',
            mineral: Mineral.fromApiName(f['mineral'] ?? '') ?? Mineral.gold,
            weightMg: f['weight_mg'] ?? '',
            latitude: f['latitude'] ?? '',
            longitude: f['longitude'] ?? '',
            capturedAt: f['captured_at'] ?? '',
          );
        } on PayloadFieldInvalid {
          built = null; // refused before signing: fine
        }
        // Either the builder refused the values, or what it built is not
        // the bad bytes (it wrote the correct header, LFs, final LF).
        expect(built, isNot(bad));
      });
    }

    // And which field stops each value-level mistake.
    for (final (name, field) in [
      ('upper-case step_id', 'step_id'),
      ('negative zero latitude', 'latitude'),
      ('latitude with 7 decimals', 'latitude'),
      ('captured_at without milliseconds', 'captured_at'),
      ('captured_at on 30 February', 'captured_at'),
    ]) {
      test('"$name" is refused at $field', () {
        final vector = listOf('negativePayloads')
            .singleWhere((v) => v['name'] == name);
        final f = looseFields(vector['payload']! as String);
        expect(
          () => buildRegistrationPayload(
            stepId: f['step_id']!,
            actorId: f['actor_id']!,
            qrCode: f['qr_code']!,
            mineral: Mineral.fromApiName(f['mineral']!)!,
            weightMg: f['weight_mg']!,
            latitude: f['latitude']!,
            longitude: f['longitude']!,
            capturedAt: f['captured_at']!,
          ),
          throwsA(
            isA<PayloadFieldInvalid>().having((e) => e.field, 'field', field),
          ),
        );
      });
    }
  });

  group('every field is checked', () {
    String buildWith({
      String stepId = '6f1d2c3a-0000-4000-8000-000000000101',
      String actorId = '3f2b6c1e-0000-4000-8000-000000000101',
      String qrCode = 'MC-DEMO-000001',
      String weightMg = '1500000',
      String latitude = '-15.419012',
      String longitude = '28.288105',
      String capturedAt = '2026-11-10T08:00:00.000Z',
    }) => buildRegistrationPayload(
      stepId: stepId,
      actorId: actorId,
      qrCode: qrCode,
      mineral: Mineral.gold,
      weightMg: weightMg,
      latitude: latitude,
      longitude: longitude,
      capturedAt: capturedAt,
    );

    for (final (field, call) in <(String, String Function())>[
      ('actor_id', () => buildWith(actorId: 'NOT-A-UUID')),
      ('qr_code', () => buildWith(qrCode: 'MC 1')),
      ('weight_mg', () => buildWith(weightMg: '0')),
      ('longitude', () => buildWith(longitude: '181.000000')),
    ]) {
      test(field, () {
        expect(
          call,
          throwsA(
            isA<PayloadFieldInvalid>().having((e) => e.field, 'field', field),
          ),
        );
      });
    }

    test('the error names the field, never the value', () {
      try {
        buildWith(qrCode: 'SECRET VALUE');
        fail('should have thrown');
      } on PayloadFieldInvalid catch (e) {
        expect(e.toString(), isNot(contains('SECRET')));
      }
    });
  });
}
