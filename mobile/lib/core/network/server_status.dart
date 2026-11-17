// Whether the API is up, for display only (plan section 5.5).
//
// Render's free service sleeps after 15 minutes without requests and takes
// about 50-60 s to wake. Without a sign of life the app would look frozen, so
// after a few seconds without an answer the screen says "Waking the server".
//
// This never polls and never keeps the server awake (decisions, Deployment (1)
// and the 14 Nov "cold start" limitation): it checks once when asked.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../errors/app_failure.dart';
import 'api_client.dart';
import 'network_providers.dart';
import 'pinned_http_client.dart';

/// What the app knows about the server. Sealed: exactly these six.
sealed class ServerStatus {
  const ServerStatus();
}

/// Not checked yet.
final class ServerUnknown extends ServerStatus {
  const ServerUnknown();
}

/// A check has started, and the answer is not late yet.
final class ServerChecking extends ServerStatus {
  const ServerChecking();
}

/// A check is running and has had no answer for a few seconds: most likely
/// the server is waking up.
final class ServerWaking extends ServerStatus {
  const ServerWaking();
}

/// The API answered 200 with {"status":"ok"}.
final class ServerReady extends ServerStatus {
  const ServerReady();
}

/// The API answered 503: it is running but cannot reach its database.
final class ServerNotReady extends ServerStatus {
  const ServerNotReady();
}

/// The check failed, for [failure].
final class ServerFailed extends ServerStatus {
  const ServerFailed(this.failure);
  final AppFailure failure;
}

/// The timings of a check, injectable so tests do not wait for real.
class ServerCheckTiming {
  const ServerCheckTiming({
    this.wakingAfter = const Duration(seconds: 3),
    this.healthTimeout = const Duration(seconds: 90),
    this.delay = realDelay,
  });

  /// How long without an answer before showing "waking".
  final Duration wakingAfter;

  /// The whole check's limit: a cold start takes about 50-60 s.
  final Duration healthTimeout;

  /// Waits; used for [wakingAfter].
  final Delay delay;
}

final serverCheckTimingProvider = Provider<ServerCheckTiming>(
  (ref) => const ServerCheckTiming(),
);

/// Holds the current [ServerStatus] and runs checks.
///
/// A Notifier is an object that owns one piece of state (`state`) and the
/// methods that change it. Widgets watch the state and rebuild when it
/// changes; they call methods like [check] to ask for a change. The widget
/// never sets the state itself.
class ServerStatusController extends Notifier<ServerStatus> {
  bool _running = false;

  /// The starting state, before any check.
  @override
  ServerStatus build() => const ServerUnknown();

  /// Checks GET /health once. Does nothing if a check is already running.
  Future<void> check() async {
    if (_running) return;
    _running = true;
    state = const ServerChecking();

    final timing = ref.read(serverCheckTimingProvider);

    // After `wakingAfter` with no answer, say "waking". `answered` stops this
    // from overwriting the result if the answer came first.
    var answered = false;
    unawaited(
      timing.delay(timing.wakingAfter).then((_) {
        if (!answered && ref.mounted) state = const ServerWaking();
      }),
    );

    ServerStatus result;
    try {
      final api = await ref.read(apiClientProvider.future);
      final body = await api.get(const ['health'], timeout: timing.healthTimeout);
      result = (body is Map && body['status'] == 'ok')
          ? const ServerReady()
          : const ServerFailed(BadResponse(status: 200));
    } on BadResponse catch (failure) {
      // /health answers 503 with its own small body, not the error format,
      // so ApiClient reports it as BadResponse(503).
      result = failure.status == 503
          ? const ServerNotReady()
          : ServerFailed(failure);
    } on AppFailure catch (failure) {
      result = ServerFailed(failure);
    } on PinningSetupError {
      // A certificate file is missing from the app. Nothing can connect, and
      // trying again will not help: shown as an unsafe connection, which has
      // no "Try again".
      result = const ServerFailed(InsecureConnection());
    } finally {
      answered = true;
      _running = false;
    }

    // The provider may have been thrown away during a long wait.
    if (ref.mounted) state = result;
  }
}

final serverStatusControllerProvider =
    NotifierProvider<ServerStatusController, ServerStatus>(
      ServerStatusController.new,
    );
