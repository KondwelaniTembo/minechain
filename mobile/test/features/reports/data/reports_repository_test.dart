// Downloading a report to the phone (reports plan, T1): the fake server,
// the real ApiClient and a real file store in a temporary folder.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/features/reports/data/report_file_store.dart';
import 'package:minechain/features/reports/data/reports_api.dart';
import 'package:minechain/features/reports/data/reports_repository.dart';
import 'package:minechain/features/reports/domain/report_request.dart';
import 'package:minechain/features/reports/domain/saved_report.dart';

import '../../../fakes/fake_reports_server.dart';

final november = TransactionsReport(
  from: DateTime.utc(2026, 11, 1),
  to: DateTime.utc(2026, 11, 30),
);
const transactionsName = 'minechain-transactions-2026-11-01-to-2026-11-30.csv';

void main() {
  late Directory cache;
  late FakeReportsServer server;
  late ReportsRepository repository;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('reports_test');
    server = FakeReportsServer();
    repository = ReportsRepository(
      api: () async => ReportsApi(server.apiClient()),
      store: ReportFileStore(cacheDirectory: () async => cache),
      clock: () => DateTime.utc(2026, 11, 21, 18, 5),
    );
  });

  tearDown(() async {
    if (await cache.exists()) await cache.delete(recursive: true);
  });

  File reportsFile(String name) => File(
    '${cache.path}${Platform.pathSeparator}reports'
    '${Platform.pathSeparator}$name',
  );

  Future<AppFailure> failureOf(Future<Object?> Function() action) async {
    try {
      await action();
    } on AppFailure catch (f) {
      return f;
    }
    fail('expected an AppFailure');
  }

  // Changed by T5b (decision Reports app): the server's BOM is left out,
  // as Google Sheets on Android showed it as "ï»¿". Everything after it is
  // still written byte for byte.
  test(
    'the file is written byte for byte without the BOM, and counted',
    () async {
      final report = await repository.download(token: 't', request: november);
      expect(report.filename, transactionsName);
      expect(report.rows, 3);
      expect(report.downloadedAt, DateTime.utc(2026, 11, 21, 18, 5));
      expect(report.path, reportsFile(transactionsName).path);
      final sent = csvFile([
        transactionsHeader,
        for (var i = 1; i <= 3; i++)
          '"s$i","MC-2026-LSK-000$i","gold","purchase"',
      ]);
      expect(sent.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      final written = await File(report.path).readAsBytes();
      expect(written, sent.sublist(3));
      expect(written.first, 0x22); // the header's opening quote
    },
  );

  test('the request goes out as planned', () async {
    await repository.download(token: 't', request: november);
    final sent = server.received.single;
    expect(sent.url.path, '/reports/transactions');
    expect(sent.url.queryParameters, {
      'from': '2026-11-01',
      'to': '2026-11-30',
    });
    expect(sent.headers['accept'], 'text/csv');
    expect(sent.headers['authorization'], 'Bearer t');
  });

  test('an earlier report is deleted: one file at a time', () async {
    await repository.download(token: 't', request: november);
    final trail = await repository.download(
      token: 't',
      request: const ConsignmentAuditTrail(knownConsignmentId),
    );
    final left = Directory('${cache.path}${Platform.pathSeparator}reports')
        .listSync()
        .map((e) => e.path)
        .toList();
    expect(left, [trail.path]);
    expect(reportsFile(transactionsName).existsSync(), isFalse);
  });

  test('a hostile server name is replaced by the request\'s own', () async {
    server.answers['transactions'] = (_) =>
        csv([transactionsHeader], '../../x.csv');
    final report = await repository.download(token: 't', request: november);
    expect(report.filename, transactionsName);
    expect(report.path, reportsFile(transactionsName).path);
    expect(report.rows, 0);
  });

  test('a refusal is thrown and nothing is written', () async {
    server.answers['transactions'] = tooLarge;
    final failure = await failureOf(
      () => repository.download(token: 't', request: november),
    );
    expect(failure, isA<ServerRefused>());
    expect((failure as ServerRefused).code, 'REPORT_TOO_LARGE');
    expect(
      Directory('${cache.path}${Platform.pathSeparator}reports').existsSync(),
      isFalse,
    );
  });

  test('the not-found ids come back as their codes', () async {
    final consignment = await failureOf(
      () => repository.download(
        token: 't',
        request: const ConsignmentAuditTrail(
          '5c0d7e21-0000-4000-8000-0000000000ff',
        ),
      ),
    );
    expect((consignment as ServerRefused).code, 'CONSIGNMENT_NOT_FOUND');
    final person = await failureOf(
      () => repository.download(
        token: 't',
        request: PersonAuditTrail(
          actorId: '3f2b6c1e-0000-4000-8000-0000000000ff',
          from: DateTime.utc(2026, 11, 1),
          to: DateTime.utc(2026, 11, 21),
        ),
      ),
    );
    expect((person as ServerRefused).code, 'USER_NOT_FOUND');
  });

  test('a folder that cannot be written is ReportNotSaved', () async {
    final file = File('${cache.path}${Platform.pathSeparator}not-a-folder');
    await file.writeAsString('x');
    final broken = ReportsRepository(
      api: () async => ReportsApi(server.apiClient()),
      // A file where the cache folder should be: creating reports/ fails.
      store: ReportFileStore(cacheDirectory: () async => Directory(file.path)),
      clock: () => DateTime.utc(2026, 11, 21),
    );
    await expectLater(
      broken.download(token: 't', request: november),
      throwsA(isA<ReportNotSaved>()),
    );
  });

  test('the store refuses an unsafe name itself', () async {
    final store = ReportFileStore(cacheDirectory: () async => cache);
    await expectLater(
      store.save(Uint8List(1), '../x.csv'),
      throwsA(isA<ArgumentError>()),
    );
    expect(isSafeReportFilename('../x.csv'), isFalse);
  });

  test('nothing about the report is logged', () async {
    final lines = <String?>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message);
    try {
      await repository.download(token: 't', request: november);
      await repository.download(
        token: 't',
        request: const ConsignmentAuditTrail(knownConsignmentId),
      );
    } finally {
      debugPrint = original;
    }
    expect(lines, isEmpty);
  });
}
