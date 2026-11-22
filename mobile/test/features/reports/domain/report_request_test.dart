// The report requests and the period rule (reports plan, T1).

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/reports/domain/report_request.dart';
import 'package:minechain/features/verification/domain/consignment_view.dart';

DateTime day(int y, int m, int d) => DateTime.utc(y, m, d);

void main() {
  group('days', () {
    test('a local date keeps its calendar day', () {
      // The date picker's local midnight, late in the day in UTC terms.
      expect(reportDay(DateTime(2026, 11, 10)), day(2026, 11, 10));
      expect(reportDay(DateTime.utc(2026, 11, 10, 23, 59)), day(2026, 11, 10));
    });

    test('the text form pads month and day', () {
      expect(utcDayText(day(2026, 1, 5)), '2026-01-05');
      expect(utcDayText(day(2026, 11, 30)), '2026-11-30');
    });

    test('the default period is the 30 UTC days ending today', () {
      // 23:30 UTC on 21 Nov is 01:30 on 22 Nov in Lusaka; every step
      // recorded so far is on or before 21 Nov UTC.
      final period = defaultPeriod(DateTime.utc(2026, 11, 21, 23, 30));
      expect(period.to, day(2026, 11, 21));
      expect(period.from, day(2026, 10, 23));
      expect(daysCounted(period.from, period.to), 30);
    });
  });

  group('the period rule, as the server counts it (both days)', () {
    test('one day', () {
      expect(daysCounted(day(2026, 11, 10), day(2026, 11, 10)), 1);
      expect(periodProblem(day(2026, 11, 10), day(2026, 11, 10)), isNull);
    });

    test('to before from', () {
      expect(
        periodProblem(day(2026, 11, 10), day(2026, 11, 9)),
        PeriodProblem.toBeforeFrom,
      );
    });

    test('366 days is the most, without a leap day', () {
      expect(periodProblem(day(2026, 1, 1), day(2027, 1, 1)), isNull);
      expect(
        periodProblem(day(2026, 1, 1), day(2027, 1, 2)),
        PeriodProblem.tooLong,
      );
    });

    test('366 days is the most, with a leap day (2028)', () {
      expect(daysCounted(day(2028, 1, 1), day(2028, 12, 31)), 366);
      expect(periodProblem(day(2028, 1, 1), day(2028, 12, 31)), isNull);
      expect(
        periodProblem(day(2028, 1, 1), day(2029, 1, 1)),
        PeriodProblem.tooLong,
      );
    });
  });

  group('transactions', () {
    test('only the period when every filter is "Any"', () {
      final request = TransactionsReport(
        from: day(2026, 11, 1),
        to: day(2026, 11, 30),
      );
      expect(request.path, ['reports', 'transactions']);
      expect(request.query, {'from': '2026-11-01', 'to': '2026-11-30'});
      expect(
        request.fallbackFilename,
        'minechain-transactions-2026-11-01-to-2026-11-30.csv',
      );
      expect(request.problem, isNull);
    });

    test('each filter as the API spells it', () {
      final request = TransactionsReport(
        from: day(2026, 11, 1),
        to: day(2026, 11, 30),
        mineral: Mineral.cobalt,
        type: StepType.handoff,
        reviewStatus: ReviewStatus.flagged,
        anchorStatus: AnchorStatus.confirmed,
      );
      expect(request.query, {
        'from': '2026-11-01',
        'to': '2026-11-30',
        'mineral': 'cobalt',
        'type': 'handoff',
        'reviewStatus': 'flagged',
        'anchorStatus': 'confirmed',
      });
    });

    test('a period problem is the request\'s problem', () {
      final request = TransactionsReport(
        from: day(2026, 1, 1),
        to: day(2027, 1, 2),
      );
      expect(request.problem, PeriodProblem.tooLong);
    });
  });

  group('audit trails', () {
    test('one consignment: its id in lower case, no dates', () {
      const request = ConsignmentAuditTrail(
        '5C0D7E21-0000-4000-8000-000000000001',
      );
      expect(request.path, ['reports', 'audit-trail']);
      expect(request.query, {
        'consignmentId': '5c0d7e21-0000-4000-8000-000000000001',
      });
      expect(
        request.fallbackFilename,
        'minechain-audit-trail-consignment-'
        '5c0d7e21-0000-4000-8000-000000000001.csv',
      );
      expect(request.problem, isNull);
    });

    test('one person: the id and the period', () {
      final request = PersonAuditTrail(
        actorId: '3F2B6C1E-0000-4000-8000-000000000001',
        from: day(2026, 11, 1),
        to: day(2026, 11, 21),
      );
      expect(request.query, {
        'actorId': '3f2b6c1e-0000-4000-8000-000000000001',
        'from': '2026-11-01',
        'to': '2026-11-21',
      });
      expect(
        request.fallbackFilename,
        'minechain-audit-trail-user-3f2b6c1e-0000-4000-8000-000000000001-'
        '2026-11-01-to-2026-11-21.csv',
      );
      expect(
        PersonAuditTrail(
          actorId: 'x',
          from: day(2026, 11, 2),
          to: day(2026, 11, 1),
        ).problem,
        PeriodProblem.toBeforeFrom,
      );
    });

    test('toString names no id', () {
      expect(
        const ConsignmentAuditTrail('5c0d7e21').toString(),
        isNot(contains('5c0d7e21')),
      );
      expect(
        PersonAuditTrail(
          actorId: '3f2b6c1e',
          from: day(2026, 11, 1),
          to: day(2026, 11, 1),
        ).toString(),
        isNot(contains('3f2b6c1e')),
      );
    });
  });
}
