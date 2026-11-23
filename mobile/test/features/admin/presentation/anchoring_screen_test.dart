// The "Anchoring" status screen inside the real app and router, with the fake
// anchoring server behind the real repository and ApiClient (anchoring status
// plan, T3): every section, every worker state, Copy, refresh, the failure
// states, and fitting small screens and large text.

import 'dart:async';
import 'dart:io' show HandshakeException, SocketException;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/clock.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/admin/presentation/anchoring_screen.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_admin_server.dart' show json200;
import '../../../fakes/fake_anchoring_server.dart';
import '../../../fakes/fake_controllers.dart';
import 'account_page_helpers.dart' show sizes, snack;

late FakeAnchoringServer server;
late AppHarness app;

final readAt = DateTime.utc(2026, 11, 23, 0, 45);

/// Starts the app as an administrator and opens "Anchoring" from the home.
Future<void> openAnchoring(
  WidgetTester tester, {
  AuthState? auth,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  app = await AppHarness.pump(
    tester,
    FakeAuthController(auth ?? signedInAs(Role.admin)),
    size: size,
    textScale: textScale,
    overrides: <Override>[
      ...server.overrides(),
      clockProvider.overrideWithValue(() => readAt),
    ],
  );
  await tapVisible(tester, find.text(AppText.anchoring));
}

Finder get pageScrollable => find
    .descendant(
      of: find.byType(AnchoringScreen),
      matching: find.byType(Scrollable),
    )
    .first;

/// Scrolls the page until [finder] is on screen.
Future<void> toPart(WidgetTester tester, Finder finder) =>
    scrollTo(tester, finder, scrollable: pageScrollable);

Finder get refreshButton => find.byTooltip(AppText.refreshStatus);

/// A busy status: a problem, a stuck step, two failed steps out of three,
/// a held consignment and steps waiting behind both.
Map<String, Object?> busyStatusJson() => anchoringStatusJson(
  state: 'paused',
  lastTick: const {
    'at': '2026-11-23T00:41:00.000Z',
    'outcome': 'paused',
    'code': 'FEE_TOO_HIGH',
    'stepId': null,
  },
  counts: const {'pending': 4, 'submitted': 1, 'confirmed': 41, 'failed': 3},
  inFlight: [inFlightJson(1)],
  failed: [
    failedJson(4),
    failedJson(5, code: 'UNRECOGNISED', attempts: 1, retryable: false),
  ],
  oldestAgeSeconds: 7300,
  onHeldConsignments: 2,
  behindFailedStep: 1,
  held: [heldJson('MC-2026-LSK-0001', pendingSteps: 2, openAlerts: 3)],
  problems: const [
    {
      'code': 'FAILED_STEPS',
      'message':
          'Some steps failed to anchor. Later steps of the same consignment '
          'wait behind them.',
    },
  ],
);

void main() {
  setUp(() => server = FakeAnchoringServer());

  group('opened from the tile', () {
    testWidgets('a healthy worker: every part, nothing waiting', (
      tester,
    ) async {
      await openAnchoring(tester);

      expect(app.path, AppRoutes.adminAnchoring);
      expect(server.received.single.url.path, '/admin/anchoring');
      expect(find.text(AppText.updatedAt(readAt.toLocal())), findsOneWidget);
      expect(find.text(AppText.workerRunning), findsOneWidget);
      await toPart(tester, find.text(AppText.noProblems));
      await toPart(tester, find.text('Waiting: 0'));
      expect(find.text('Sent, not confirmed yet: 0'), findsOneWidget);
      await toPart(tester, find.text('On the blockchain: 41'));
      await toPart(tester, find.text('Failed: 0'));
      await toPart(
        tester,
        find.text(
          AppText.lastAnchoredAt(DateTime.utc(2026, 11, 21, 0, 27).toLocal()),
        ),
      );
      await toPart(
        tester,
        find.text(
          AppText.workerLastRan(
            DateTime.utc(2026, 11, 23, 0, 41).toLocal(),
            AppText.tickIdle,
          ),
        ),
      );
      await toPart(tester, find.text(fakeRecorder));
      expect(find.text(AppText.recorderWalletNote), findsOneWidget);
      await toPart(tester, find.text(fakeContract));
    });

    // A screen tall enough for the whole page, so nothing is left unbuilt by
    // the list and an absence below means the part is really left out.
    testWidgets('nothing waiting, sent, failed or held: those parts are left '
        'out, and there is no run or retry button', (tester) async {
      await openAnchoring(tester, size: const Size(400, 4000));

      // The whole page is built: its first and last parts are both there.
      expect(find.text(AppText.workerRunning), findsOneWidget);
      expect(find.text(AppText.walletHeading), findsOneWidget);

      expect(find.text(AppText.waitingHeading), findsNothing);
      // "Sent, not confirmed yet" stays only as the count's word.
      expect(find.text(AppText.countSent), findsNothing);
      expect(find.text(AppText.heldHeading), findsNothing);
      // "Failed" stays only as the count's word ("Failed: 0").
      expect(find.text(AppText.chainFailed), findsNothing);
      expect(find.text(AppText.canBeRetried), findsNothing);
      // Read-only (Scope (11)).
      expect(find.text('Run now'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('the same tall screen with a busy worker shows every part', (
      tester,
    ) async {
      server.status = busyStatusJson();
      await openAnchoring(tester, size: const Size(400, 4000));

      expect(find.text(AppText.waitingHeading), findsOneWidget);
      // The count's line, and the section's heading.
      expect(find.textContaining(AppText.countSent), findsNWidgets(2));
      expect(find.text(AppText.heldHeading), findsOneWidget);
      expect(find.text(AppText.canBeRetried), findsOneWidget);
    });

    testWidgets('a busy worker: problems, sent, failed, waiting and held', (
      tester,
    ) async {
      server.status = busyStatusJson();
      await openAnchoring(tester);

      expect(find.text(AppText.workerPaused), findsOneWidget);
      await toPart(tester, find.textContaining('Some steps failed'));
      expect(find.text(AppText.noProblems), findsNothing);
      await toPart(tester, find.text('Waiting: 4'));
      await toPart(
        tester,
        find.text(
          AppText.workerLastRan(
            DateTime.utc(2026, 11, 23, 0, 41).toLocal(),
            AppText.tickPaused,
          ),
        ),
      );

      // Waiting.
      await toPart(tester, find.text('Oldest waiting: 2 hours'));
      await toPart(
        tester,
        find.text('2 on held consignments: an officer must decide first'),
      );
      await toPart(tester, find.text('1 behind a failed step'));

      // Sent, not confirmed yet.
      await toPart(tester, find.text('Handoff 9d4e5f60'));
      await toPart(tester, find.text('Sent 10 minutes ago'));
      await toPart(tester, find.text(AppText.sentStepStuck));
      await toPart(tester, find.text('Last resend refused: FEE_TOO_HIGH'));
      await toPart(tester, find.text(fakeTxHash));

      // Failed: two shown of three; only the first may be retried.
      final first = find.byKey(ValueKey('failed-${anchorStepId(4)}'));
      final second = find.byKey(ValueKey('failed-${anchorStepId(5)}'));
      await toPart(tester, first);
      expect(
        find.descendant(
          of: first,
          matching: find.text('Reason: RPC_UNAVAILABLE'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: first, matching: find.text('3 attempts')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: first, matching: find.text(AppText.canBeRetried)),
        findsOneWidget,
      );
      await toPart(tester, second);
      expect(
        find.descendant(
          of: second,
          matching: find.text('Reason: UNRECOGNISED'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: second, matching: find.text(AppText.canBeRetried)),
        findsNothing,
      );
      await toPart(tester, find.text(AppText.newestFailed(2, 3)));

      // Held.
      await toPart(tester, find.text('MC-2026-LSK-0001'));
      expect(find.text('2 steps waiting, 3 open alerts'), findsOneWidget);
    });

    testWidgets('switched off: no tick, nothing anchored, no addresses', (
      tester,
    ) async {
      server.status = anchoringStatusJson(
        state: 'disabled',
        lastTick: null,
        recorderAddress: null,
        contractAddress: null,
        lastConfirmedAt: null,
      );
      await openAnchoring(tester);

      expect(find.text(AppText.workerDisabled), findsOneWidget);
      await toPart(tester, find.text(AppText.nothingAnchoredYet));
      await toPart(tester, find.text(AppText.workerNotRunYet));
      expect(find.text(AppText.walletHeading), findsNothing);
    });
  });

  group('every worker state in words', () {
    const states = {
      'running': AppText.workerRunning,
      'paused': AppText.workerPaused,
      'backoff': AppText.workerBackoff,
      'stopped': AppText.workerStopped,
      'not_started': AppText.workerNotStarted,
      'disabled': AppText.workerDisabled,
      'sleeping': AppText.workerUnknown,
    };
    for (final MapEntry(key: state, value: words) in states.entries) {
      testWidgets(state, (tester) async {
        server.status = anchoringStatusJson(state: state);
        await openAnchoring(tester);
        expect(find.text(words), findsOneWidget);
      });
    }
  });

  testWidgets('Copy puts the whole address on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await openAnchoring(tester);

    final copyRecorder = find.descendant(
      of: find.byKey(const ValueKey('copy-recorder')),
      matching: find.text(AppText.copy),
    );
    await toPart(tester, copyRecorder);
    await tester.tap(copyRecorder);
    await tester.pump();

    expect(copied, fakeRecorder);
    expect(snack(AppText.copied), findsOneWidget);
  });

  group('refresh', () {
    testWidgets('the button reads it again and shows the new answer', (
      tester,
    ) async {
      await openAnchoring(tester);
      server.status = anchoringStatusJson(state: 'backoff');
      await tester.tap(refreshButton);
      await tester.pumpAndSettle();

      expect(server.received, hasLength(2));
      expect(find.text(AppText.workerBackoff), findsOneWidget);
    });

    testWidgets('pulling the page down reads it again', (tester) async {
      await openAnchoring(tester);
      await tester.fling(
        find.text(AppText.workerRunning),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(server.received, hasLength(2));
    });

    testWidgets('while a read is on its way: the last answer stays, the '
        'button waits', (tester) async {
      await openAnchoring(tester);
      server.hold = Completer<void>();
      await tester.tap(refreshButton);
      await tester.pump();

      expect(find.text(AppText.workerRunning), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.refresh),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );

      server.hold!.complete();
      server.hold = null;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.refresh),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('a failed refresh keeps the answer and says why', (
      tester,
    ) async {
      await openAnchoring(tester);
      server.answer = (_) => throw const SocketException('test');
      await tester.tap(refreshButton);
      await tester.pumpAndSettle();

      expect(find.text(AppText.workerRunning), findsOneWidget);
      expect(snack(AppText.noConnection), findsOneWidget);
    });
  });

  group('failures', () {
    testWidgets('offline: the sentence and "Try again"', (tester) async {
      server.answer = (_) => throw const SocketException('test');
      await openAnchoring(tester);
      expect(find.text(AppText.noConnection), findsOneWidget);

      server.answer = null;
      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, AppText.tryAgain),
      );
      expect(find.text(AppText.workerRunning), findsOneWidget);
    });

    testWidgets('an unsafe connection: no "Try again"', (tester) async {
      server.answer = (_) => throw const HandshakeException('test');
      await openAnchoring(tester);
      expect(find.text(AppText.insecureConnection), findsOneWidget);
      expect(find.widgetWithText(FilledButton, AppText.tryAgain), findsNothing);
    });

    testWidgets('an answer that is not the documented shape', (tester) async {
      server.answer = (_) => json200({'worker': 'running'});
      await openAnchoring(tester);
      expect(find.text(AppText.badResponse), findsOneWidget);
    });

    testWidgets('token expired: the password first, then the status', (
      tester,
    ) async {
      await openAnchoring(
        tester,
        auth: SignedInNeedsPassword(userOf(Role.admin)),
      );
      expect(find.text(AppText.anchoringNeedsPassword), findsOneWidget);
      expect(server.received, isEmpty);

      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, AppText.enterYourPassword),
      );
      await tester.enterText(
        find.descendant(
          of: find.byType(PasswordPromptDialog),
          matching: find.byType(TextField),
        ),
        fakePassword,
      );
      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, AppText.continueLabel),
      );
      expect(find.text(AppText.workerRunning), findsOneWidget);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in sizes) {
      testWidgets('a busy worker, top to bottom: $name', (tester) async {
        server.status = busyStatusJson();
        await openAnchoring(tester, size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        await toPart(tester, find.text(fakeTxHash));
        expect(tester.takeException(), isNull);
        await toPart(tester, find.text('MC-2026-LSK-0001'));
        expect(tester.takeException(), isNull);
        await toPart(tester, find.text(fakeContract));
        expect(tester.takeException(), isNull);
      });
    }
  });
}
