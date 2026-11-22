// The download-then-share controller (reports plan, T2 and T3), without
// screens: the fake server, the real repository, the fake store and share
// sheet.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/clock.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/reports/data/report_file_store.dart';
import 'package:minechain/features/reports/data/report_sharer.dart';
import 'package:minechain/features/reports/domain/report_request.dart';
import 'package:minechain/features/reports/presentation/report_download_controller.dart';

import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_report_files.dart';
import '../../../fakes/fake_reports_server.dart';

final november = TransactionsReport(
  from: DateTime.utc(2026, 11, 1),
  to: DateTime.utc(2026, 11, 30),
);
const name = 'minechain-transactions-2026-11-01-to-2026-11-30.csv';

void main() {
  late FakeReportsServer server;
  late FakeReportFileStore store;
  late FakeReportSharer sharer;
  late FakeAuthController auth;
  late ProviderContainer container;

  ProviderContainer start([AuthState? state]) {
    auth = FakeAuthController(state ?? signedInAs(Role.officer));
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        ...fakeOverrides(auth),
        ...server.overrides(),
        ...reportFileOverrides(store, sharer),
        clockProvider.overrideWithValue(() => DateTime.utc(2026, 11, 21, 16)),
      ],
    );
    // autoDispose: something must listen, or the state is dropped.
    container.listen(
      reportDownloadProvider(ReportSlot.transactions),
      (_, _) {},
    );
    return container;
  }

  ReportDownloadState state() =>
      container.read(reportDownloadProvider(ReportSlot.transactions));
  ReportDownloadController controller() =>
      container.read(reportDownloadProvider(ReportSlot.transactions).notifier);

  setUp(() {
    server = FakeReportsServer();
    store = FakeReportFileStore();
    sharer = FakeReportSharer();
  });

  test('download, save, then the share sheet with the saved file', () async {
    start();
    await controller().download(november);
    final ready = state() as ReportReady;
    expect(ready.share, ShareStatus.shared);
    expect(ready.report.filename, name);
    expect(ready.report.rows, 3);
    expect(ready.report.downloadedAt, DateTime.utc(2026, 11, 21, 16));
    expect(store.saved.single.$1, name);
    expect(sharer.shared.single.path, '/cache/reports/$name');
  });

  test('the share sheet is "opening" until it answers', () async {
    sharer.hold = Completer<void>();
    start();
    final running = controller().download(november);
    await pumpEventQueue();
    expect((state() as ReportReady).share, ShareStatus.opening);
    // A tap meanwhile downloads nothing more.
    await controller().download(november);
    expect(server.received, hasLength(1));
    sharer.hold!.complete();
    await running;
    expect((state() as ReportReady).share, ShareStatus.shared);
  });

  group('each share outcome', () {
    final cases = {
      ShareOutcome.dismissed: ShareStatus.notShared,
      ShareOutcome.unknown: ShareStatus.unknown,
    };
    cases.forEach((outcome, status) {
      test('$outcome gives $status', () async {
        sharer.outcome = outcome;
        start();
        await controller().download(november);
        expect((state() as ReportReady).share, status);
      });
    });

    test('a share that throws is "failed", with the file kept', () async {
      sharer.error = PlatformException(code: 'x');
      start();
      await controller().download(november);
      final ready = state() as ReportReady;
      expect(ready.share, ShareStatus.failed);
      expect(ready.report.filename, name);
    });
  });

  test('"Share again" shares the same file without downloading', () async {
    sharer.outcome = ShareOutcome.dismissed;
    start();
    await controller().download(november);
    sharer.outcome = ShareOutcome.shared;
    await controller().shareAgain();
    expect(sharer.shared, hasLength(2));
    expect(sharer.shared.last.path, sharer.shared.first.path);
    expect(server.received, hasLength(1));
    expect((state() as ReportReady).share, ShareStatus.shared);
  });

  test('a full phone is ReportNotSaved, and nothing is shared', () async {
    store.full = true;
    start();
    await controller().download(november);
    expect((state() as ReportFailed).failure, isA<ReportNotSaved>());
    expect(sharer.shared, isEmpty);
  });

  test(
    'a refusal is ReportFailed, and "Try again" sends the same query',
    () async {
      server.answers['transactions'] = tooLarge;
      start();
      await controller().download(november);
      final failed = state() as ReportFailed;
      expect((failed.failure as ServerRefused).code, 'REPORT_TOO_LARGE');
      server.answers.clear();
      await controller().retry();
      expect(state(), isA<ReportReady>());
      expect(server.received, hasLength(2));
      expect(
        server.received.last.url.queryParameters,
        server.received.first.url.queryParameters,
      );
    },
  );

  test('a period with a problem is never sent', () async {
    start();
    await controller().download(
      TransactionsReport(
        from: DateTime.utc(2026, 1, 1),
        to: DateTime.utc(2027, 1, 2),
      ),
    );
    expect(state(), isA<ReportIdle>());
    expect(server.received, isEmpty);
  });

  test('an ended session asks for the password first, nothing sent', () async {
    start(SignedInNeedsPassword(userOf(Role.officer)));
    await controller().download(november);
    expect(state(), isA<ReportNeedsPassword>());
    expect(server.received, isEmpty);

    auth.setState(signedInAs(Role.officer));
    await controller().retry();
    expect(state(), isA<ReportReady>());
    expect(server.received.single.url.queryParameters, november.query);
  });

  test(
    'a session that ends during the download asks for the password',
    () async {
      server.answers['transactions'] = (_) {
        // What the real AuthController does on TOKEN_EXPIRED.
        auth.setState(SignedInNeedsPassword(userOf(Role.officer)));
        return refusal(401, 'TOKEN_EXPIRED', 'Your session has expired.');
      };
      start();
      await controller().download(november);
      expect(state(), isA<ReportNeedsPassword>());
    },
  );

  test('the states name no id, path or filename', () async {
    start();
    await controller().download(
      const ConsignmentAuditTrail(knownConsignmentId),
    );
    expect(state().toString(), isNot(contains(knownConsignmentId)));
    expect(state().toString(), isNot(contains('cache')));
  });
}
