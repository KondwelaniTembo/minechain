// Typed and GPS corners (GPS zones plan, T1, Q1 and Q3): what is taken, what
// is refused and why, how a corner is shown, and which corner a server field
// path names.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/admin/domain/corner_input.dart';
import 'package:minechain/features/admin/domain/gps_zone.dart';

void main() {
  group('parseCorner takes', () {
    final good = <String, ZoneCorner>{
      // As Google Maps shows a dropped pin.
      '-15.418327, 28.289494': const ZoneCorner(-15.418327, 28.289494),
      '-15.418327,28.289494': const ZoneCorner(-15.418327, 28.289494),
      '  -15.418327 28.289494  ': const ZoneCorner(-15.418327, 28.289494),
      '-15.418327 , 28.289494': const ZoneCorner(-15.418327, 28.289494),
      '-13, 25': const ZoneCorner(-13, 25),
      '+10.5, 30': const ZoneCorner(10.5, 30),
      // The typographic minus (U+2212).
      '−15.4, 28.2': const ZoneCorner(-15.4, 28.2),
      // The edges of the ranges.
      '90, 180': const ZoneCorner(90, 180),
      '-90, -180': const ZoneCorner(-90, -180),
      // Swapped, but in range: the server's Zambia box refuses it with the
      // sentence that explains the order.
      '28.29, -15.42': const ZoneCorner(28.29, -15.42),
    };
    good.forEach((text, corner) {
      test('"$text"', () {
        final input = parseCorner(text);
        expect(input.problem, isNull);
        expect(input.corner, corner);
      });
    });
  });

  group('parseCorner refuses', () {
    final bad = <String, CornerProblem>{
      '': CornerProblem.notTwoNumbers,
      '-15.418327': CornerProblem.notTwoNumbers,
      '-15.41, 28.28, 1200': CornerProblem.notTwoNumbers,
      'south, east': CornerProblem.notTwoNumbers,
      '-15.41°, 28.28°': CornerProblem.notTwoNumbers,
      '1e1, 28': CornerProblem.notTwoNumbers,
      '.5, 28': CornerProblem.notTwoNumbers,
      '-15., 28': CornerProblem.notTwoNumbers,
      '-15,41; 28,28': CornerProblem.notTwoNumbers,
      // Q3: more than 6 places is refused as typed, never rounded.
      '-15.4183274, 28.289494': CornerProblem.tooManyDecimals,
      '-15.418327, 28.2894941': CornerProblem.tooManyDecimals,
      '90.5, 28': CornerProblem.latitudeOutOfRange,
      '-91, 28': CornerProblem.latitudeOutOfRange,
      '-15, 180.000001': CornerProblem.longitudeOutOfRange,
      '-15, -181': CornerProblem.longitudeOutOfRange,
    };
    bad.forEach((text, problem) {
      test('"$text": ${problem.name}', () {
        final input = parseCorner(text);
        expect(input.corner, isNull);
        expect(input.problem, problem);
      });
    });
  });

  group('a GPS reading', () {
    test('is rounded to 6 decimal places', () {
      final corner = cornerFromReading(-15.41832749, 28.28949451);
      expect(corner, const ZoneCorner(-15.418327, 28.289495));
    });

    test('is sent as exactly 6 places at most', () {
      final corner = cornerFromReading(-15.123456789, 28.987654321);
      expect(jsonEncode(corner.toJson()), '[-15.123457,28.987654]');
    });
  });

  group('cornerText', () {
    test('latitude first, no trailing zeros', () {
      expect(
        cornerText(const ZoneCorner(-15.418327, 28.289494)),
        '-15.418327, 28.289494',
      );
      expect(cornerText(const ZoneCorner(-13.45, 25.8)), '-13.45, 25.8');
      expect(cornerText(const ZoneCorner(-13, 25)), '-13, 25');
      expect(cornerText(const ZoneCorner(-0.0000001, 0)), '0, 0');
    });

    test('reads back as the same corner', () {
      for (final corner in const [
        ZoneCorner(-15.418327, 28.289494),
        ZoneCorner(-8.000001, 33.999999),
        ZoneCorner(-13, 25),
      ]) {
        expect(parseCorner(cornerText(corner)).corner, corner);
      }
    });
  });

  group('cornerIndexOfField', () {
    test('a corner or one of its numbers', () {
      expect(cornerIndexOfField('boundary.0'), 0);
      expect(cornerIndexOfField('boundary.3'), 3);
      expect(cornerIndexOfField('boundary.1.0'), 1);
      expect(cornerIndexOfField('boundary.12.1'), 12);
    });

    test('the whole boundary or another field: none', () {
      expect(cornerIndexOfField('boundary'), isNull);
      expect(cornerIndexOfField('name'), isNull);
      expect(cornerIndexOfField('boundary.x'), isNull);
      expect(cornerIndexOfField('boundary.1.2'), isNull);
      expect(cornerIndexOfField('xboundary.1'), isNull);
    });
  });

  test('the limits are the API\'s', () {
    expect(minZoneCorners, 3);
    expect(maxZoneCorners, 100);
    expect(maxCornerDecimals, 6);
    expect((zoneNameMin, zoneNameMax, zoneLicenceMax), (3, 100, 50));
  });
}
