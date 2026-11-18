// The GPS policy (plan §5, Q3): 25 m, not mocked, fresh within 30 s.

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/registration/domain/gps_fix.dart';

import '../../../fakes/fake_registration.dart';

void main() {
  final now = DateTime.utc(2026, 11, 17, 10);

  test('6 m, just now, real: usable', () {
    expect(fixProblem(reading(now), now), isNull);
  });

  test('exactly 25 m: usable', () {
    expect(fixProblem(reading(now, accuracyM: 25), now), isNull);
  });

  test('25.1 m: too inaccurate', () {
    expect(
      fixProblem(reading(now, accuracyM: 25.1), now),
      FixProblem.tooInaccurate,
    );
  });

  test('no accuracy reported: refused, even though accuracy reads 0.0', () {
    expect(
      fixProblem(reading(now, accuracyM: 0, hasAccuracy: false), now),
      FixProblem.noAccuracy,
    );
  });

  test('mocked: refused, however accurate it claims to be', () {
    expect(
      fixProblem(reading(now, accuracyM: 1, mocked: true), now),
      FixProblem.mocked,
    );
  });

  test('30 s old: still usable; 31 s: stale', () {
    expect(
      fixProblem(reading(now.subtract(const Duration(seconds: 30))), now),
      isNull,
    );
    expect(
      fixProblem(reading(now.subtract(const Duration(seconds: 31))), now),
      FixProblem.stale,
    );
  });

  test('a fix from the future beyond a moment: stale', () {
    expect(
      fixProblem(reading(now.add(const Duration(minutes: 1))), now),
      FixProblem.stale,
    );
  });

  test('toString holds no coordinates', () {
    expect(reading(now).toString(), isNot(contains('15.4')));
  });
}
