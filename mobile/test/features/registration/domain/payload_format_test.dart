// The value rules (signing spec, sections 3 and 4), including every example
// the spec gives for the two formatters.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/registration/domain/payload_format.dart';

void main() {
  group('formatCoordinate (the spec\'s own examples)', () {
    for (final (input, expected) in [
      (-15.4197512, '-15.419751'),
      (28.288, '28.288000'),
      (28.2874968, '28.287497'),
      (-0.0000004, '0.000000'), // never -0.000000
      (0.0, '0.000000'),
      (-0.0, '0.000000'),
      (90.0, '90.000000'),
      (-180.0, '-180.000000'),
      (5.0000004, '5.000000'),
      (-5.0000006, '-5.000001'), // halves and above round away from zero
    ]) {
      test('$input -> $expected', () {
        expect(formatCoordinate(input), expected);
      });
    }
  });

  group('coordinateText', () {
    test('a normal fix', () {
      expect(coordinateText(-15.4197512, latitude: true), '-15.419751');
    });

    test('out of range after rounding: refused', () {
      expect(coordinateText(90.0000006, latitude: true), isNull);
      expect(coordinateText(180.0000006, latitude: false), isNull);
      expect(coordinateText(100.0, latitude: true), isNull);
    });

    test('180 is fine for a longitude, not a latitude', () {
      expect(coordinateText(180.0, latitude: false), '180.000000');
      expect(coordinateText(180.0, latitude: true), isNull);
    });

    test('not a number: refused, never a crash', () {
      expect(coordinateText(double.nan, latitude: true), isNull);
      expect(coordinateText(double.infinity, latitude: false), isNull);
    });
  });

  group('formatCapturedAt', () {
    test('truncates microseconds, never rounds (123 ms 456 µs -> .123Z)', () {
      final time = DateTime.utc(2026, 11, 10, 8, 0, 0, 123, 456);
      expect(formatCapturedAt(time), '2026-11-10T08:00:00.123Z');
    });

    test('999 ms 999 µs stays in the same second', () {
      final time = DateTime.utc(2026, 11, 10, 8, 0, 0, 999, 999);
      expect(formatCapturedAt(time), '2026-11-10T08:00:00.999Z');
    });

    test('a local time is written in UTC', () {
      final local = DateTime.utc(2026, 11, 10, 8).toLocal();
      expect(formatCapturedAt(local), '2026-11-10T08:00:00.000Z');
    });

    test('matches the spec vector', () {
      expect(
        formatCapturedAt(DateTime.utc(2026, 11, 10, 14, 30, 5, 250)),
        '2026-11-10T14:30:05.250Z',
      );
    });
  });

  group('newStepId', () {
    test('a lower-case version-4 UUID', () {
      final id = newStepId();
      expect(isLowerCaseUuid(id), isTrue);
      expect(id[14], '4'); // the version
      expect('89ab'.contains(id[19]), isTrue); // the variant
    });

    test('a fresh one each time', () {
      final ids = {for (var i = 0; i < 1000; i++) newStepId()};
      expect(ids, hasLength(1000));
    });

    test('the same source of randomness gives the same id (for tests)', () {
      expect(newStepId(Random(7)), newStepId(Random(7)));
    });
  });

  group('grammar', () {
    test('step and actor ids: lower case only', () {
      expect(isLowerCaseUuid('6f1d2c3a-0000-4000-8000-000000000101'), isTrue);
      expect(isLowerCaseUuid('6F1D2C3A-0000-4000-8000-000000000101'), isFalse);
      expect(isLowerCaseUuid('6f1d2c3a00004000800000000000000101'), isFalse);
    });

    for (final (value, ok) in [
      ('MC-DEMO-000001', true),
      ('MC/2026/001', true),
      ('a.b_c:d', true),
      ('ABCD', true), // 4, the shortest
      ('ABC', false),
      ('A' * 128, true),
      ('A' * 129, false),
      ('MC 2026', false), // a space
      ('MC-2026\n', false),
      ('https://example.org/x?y', false), // ? is not allowed
      ('MÇ-2026', false), // not ASCII
    ]) {
      test('qr_code "$value" -> $ok', () => expect(isQrCode(value), ok));
    }

    for (final (value, ok) in [
      ('1', true),
      ('1500000', true),
      ('9223372036854775807', true),
      ('9223372036854775808', false),
      ('0', false),
      ('01500000', false), // a leading zero
      ('-1', false),
      ('+1', false),
      ('1.5', false),
      ('', false),
    ]) {
      test('weight_mg "$value" -> $ok', () => expect(isWeightMg(value), ok));
    }

    for (final (value, latitude, ok) in [
      ('-15.419012', true, true),
      ('0.000000', true, true),
      ('-0.000000', true, false), // the spec refuses negative zero
      ('90.000000', true, true),
      ('90.000001', true, false),
      ('-90.000000', true, true),
      ('180.000000', false, true),
      ('180.000001', false, false),
      ('-15.4190123', true, false), // 7 decimals
      ('-15.41901', true, false), // 5 decimals
      ('015.419012', true, false), // a leading zero
      ('15', true, false),
    ]) {
      test('coordinate "$value" (latitude: $latitude) -> $ok', () {
        expect(isCoordinate(value, latitude: latitude), ok);
      });
    }

    for (final (value, ok) in [
      ('2026-11-10T08:00:00.000Z', true),
      ('2026-11-10T08:00:00Z', false), // no milliseconds
      ('2026-11-10T08:00:00.0000Z', false),
      ('2026-11-10T08:00:00.000+00:00', false),
      ('2026-02-30T08:00:00.000Z', false), // not a real day
      ('2026-02-29T08:00:00.000Z', false), // 2026 is not a leap year
      ('2028-02-29T08:00:00.000Z', true),
      ('2026-11-10T24:00:00.000Z', false),
      ('2026-11-10T08:60:00.000Z', false),
      ('2026-13-01T08:00:00.000Z', false),
    ]) {
      test('captured_at "$value" -> $ok', () {
        expect(isCapturedAt(value), ok);
      });
    }

    test('payload text: printable ASCII and LF only', () {
      expect(isPayloadText('a=b\n'), isTrue);
      expect(isPayloadText('a=b\r\n'), isFalse);
      expect(isPayloadText('a = b\n'), isFalse); // a space
      expect(isPayloadText('a=é\n'), isFalse);
    });
  });
}
