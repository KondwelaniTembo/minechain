// The handoff payload against docs/signing-spec.md (section 3's handoff
// example) and docs/signing-vectors.json, byte for byte. Both files are only
// read here, never regenerated.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/handoff/domain/handoff_payload.dart';

// `flutter test` runs with mobile/ as the working directory.
final Map<String, Object?> vectors = jsonDecode(
  File('../docs/signing-vectors.json').readAsStringSync(),
) as Map<String, Object?>;

List<Map<String, Object?>> listOf(String key) =>
    (vectors[key]! as List).cast<Map<String, Object?>>();

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The spec's handoff example, taken from the document itself so the test
/// follows the spec rather than a copy of it. In the spec each line ends
/// with `⏎`, which stands for LF and is not part of the bytes. The file's
/// own line breaks (CRLF in a Windows checkout) are dropped: only `⏎` counts.
String specHandoffExample() {
  final spec = File('../docs/signing-spec.md').readAsStringSync();
  final start = spec.indexOf('minechain-step/1/handoff⏎');
  expect(start, isNonNegative, reason: 'the spec has a handoff example');
  final end = spec.indexOf('```', start);
  return spec
      .substring(start, end)
      .trimRight()
      .split('\n')
      .map((line) => line.replaceAll('\r', '').replaceAll('⏎', '\n'))
      .join();
}

/// A payload's `key=value` lines as a map (no header).
Map<String, String> fieldsOf(String payload) => {
  for (final line in payload.split('\n').skip(1).where((l) => l.isNotEmpty))
    line.substring(0, line.indexOf('=')): line.substring(line.indexOf('=') + 1),
};

String buildFrom(Map<String, String> f) => buildHandoffPayload(
  stepId: f['step_id']!,
  actorId: f['actor_id']!,
  qrCode: f['qr_code']!,
  weightMg: f['weight_mg']!,
  latitude: f['latitude']!,
  longitude: f['longitude']!,
  capturedAt: f['captured_at']!,
);

void main() {
  group('the signing spec\'s handoff example', () {
    test('is built exactly', () {
      final example = specHandoffExample();
      expect(example, startsWith('minechain-step/1/handoff\n'));
      expect(buildFrom(fieldsOf(example)), example);
    });
  });

  group('the positive handoff vector', () {
    final vector = listOf('positive')
        .singleWhere((v) => v['name'] == 'handoff');
    final fields = vector['fields']! as Map<String, Object?>;

    String build() => buildHandoffPayload(
      stepId: fields['stepId']! as String,
      actorId: fields['actorId']! as String,
      qrCode: fields['qrCode']! as String,
      weightMg: fields['weightMg']! as String,
      latitude: fields['latitude']! as String,
      longitude: fields['longitude']! as String,
      capturedAt: fields['capturedAt']! as String,
    );

    test('has no mineral among its fields', () {
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

    test('eight lines, each ending with LF, the last included', () {
      final text = build();
      expect(text.endsWith('\n'), isTrue);
      expect('\n'.allMatches(text), hasLength(8));
      expect(text.contains('\r'), isFalse);
    });

    test('no mineral line', () {
      expect(build(), isNot(contains('mineral=')));
    });
  });

  group('the handoff negative vectors can never be produced', () {
    test('"mineral line on a handoff"', () {
      final bad = listOf('negativePayloads')
          .singleWhere((v) => v['name'] == 'mineral line on a handoff');
      final payload = bad['payload']! as String;
      // The same values, built properly, give the 8-line handoff, never the
      // 9-line payload with a mineral.
      final built = buildFrom(fieldsOf(payload));
      expect(built, isNot(payload));
      expect(
        built,
        listOf('positive')
            .singleWhere((v) => v['name'] == 'handoff')['payload'],
      );
    });

    test('"handoff signature under a purchase header"', () {
      final bad = listOf('negativeSignatures').singleWhere(
        (v) => v['name'] == 'handoff signature under a purchase header',
      );
      final payload = bad['payload']! as String;
      final built = buildFrom(fieldsOf(payload));
      expect(built, isNot(payload));
      expect(built, startsWith('minechain-step/1/handoff\n'));
    });
  });

  group('every field is checked', () {
    String buildWith({
      String stepId = '6f1d2c3a-0000-4000-8000-000000000102',
      String actorId = '3f2b6c1e-0000-4000-8000-000000000102',
      String qrCode = 'MC-DEMO-000001',
      String weightMg = '1495000',
      String latitude = '-15.418900',
      String longitude = '28.288700',
      String capturedAt = '2026-11-10T14:30:05.250Z',
    }) => buildHandoffPayload(
      stepId: stepId,
      actorId: actorId,
      qrCode: qrCode,
      weightMg: weightMg,
      latitude: latitude,
      longitude: longitude,
      capturedAt: capturedAt,
    );

    for (final (field, call) in <(String, String Function())>[
      (
        'step_id',
        () => buildWith(stepId: '6F1D2C3A-0000-4000-8000-000000000102'),
      ),
      ('actor_id', () => buildWith(actorId: 'NOT-A-UUID')),
      ('qr_code', () => buildWith(qrCode: 'MC 1')),
      ('weight_mg', () => buildWith(weightMg: '0')),
      ('weight_mg', () => buildWith(weightMg: '01495000')),
      ('weight_mg', () => buildWith(weightMg: '1495.5')),
      ('latitude', () => buildWith(latitude: '-0.000000')),
      ('latitude', () => buildWith(latitude: '-15.4189001')),
      ('longitude', () => buildWith(longitude: '181.000000')),
      ('captured_at', () => buildWith(capturedAt: '2026-11-10T14:30:05Z')),
      ('captured_at', () => buildWith(capturedAt: '2026-02-30T14:30:05.250Z')),
    ]) {
      test('$field is refused', () {
        expect(
          call,
          throwsA(
            isA<PayloadFieldInvalid>().having((e) => e.field, 'field', field),
          ),
        );
      });
    }

    test(
      'the default values are valid (so each case above fails on its field)',
      () {
        expect(buildWith(), startsWith('minechain-step/1/handoff\n'));
      },
    );

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
