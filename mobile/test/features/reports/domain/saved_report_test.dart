// The names a report is written under (reports plan, T1).

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/reports/domain/report_request.dart';
import 'package:minechain/features/reports/domain/saved_report.dart';

void main() {
  final request = TransactionsReport(
    from: DateTime.utc(2026, 11, 1),
    to: DateTime.utc(2026, 11, 30),
  );
  const fallback = 'minechain-transactions-2026-11-01-to-2026-11-30.csv';

  test('the server\'s safe name is kept', () {
    expect(
      reportFilename(
        'minechain-audit-trail-consignment-5c0d7e21-0000-4000-8000-000000000001.csv',
        request,
      ),
      'minechain-audit-trail-consignment-5c0d7e21-0000-4000-8000-000000000001.csv',
    );
  });

  group('any other name gives the request\'s own', () {
    const refused = [
      null,
      '',
      '../minechain-x.csv',
      'minechain-../x.csv',
      'minechain-a..b.csv',
      'minechain-x.txt',
      'minechain-X.csv',
      'report.csv',
      'minechain-a/b.csv',
      'minechain-a\\b.csv',
      'minechain-.csv',
    ];
    for (final name in refused) {
      test('$name', () {
        expect(reportFilename(name, request), fallback);
      });
    }
  });

  test('a request id with odd characters gives the last-resort name', () {
    const odd = ConsignmentAuditTrail('../../x');
    expect(reportFilename(null, odd), lastResortReportFilename);
    expect(isSafeReportFilename(lastResortReportFilename), isTrue);
  });

  test('toString has no path or name', () {
    final report = SavedReport(
      path: '/cache/reports/minechain-x.csv',
      filename: 'minechain-x.csv',
      rows: 4,
      downloadedAt: DateTime.utc(2026, 11, 21),
    );
    expect(report.toString(), 'SavedReport(rows: 4)');
  });
}
