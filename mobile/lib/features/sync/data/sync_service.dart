// Sends the saved steps to the server (plan M6 and §3; FR-03, FR-07).
//
// One run, in order:
//  1. One run at a time: a second trigger joins the running one and gets
//     its report (approved point 6).
//  2. The session must be SignedIn with a token that has not run out.
//  3. Nothing waiting: stop here, before the key or the network.
//  4. The device key must be ready, or registered first (plan §4).
//  5. Batches of up to 50, oldest first, the stored payload and signature
//     exactly as saved. Each answer is written in one local transaction,
//     matched by index and checked by stepId.
//  6. Repeat until nothing is due, or a whole-request failure stops it.
//
// What is never done:
//  - rebuilding or re-signing a payload (signing spec, section 4);
//  - changing a row because of a network error, a timeout or a 500 (plan
//    §3, approved point 4): the row stays queued, and a resend is safe;
//  - sending a rejected step again;
//  - logging anything: no payload, signature, token or database key, and no
//    SQLite text (the repository turns SQLite errors into its own types).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/network/network_providers.dart';
import '../../../core/network/session_events.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/domain/user.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../device_key/presentation/device_key_controller.dart';
import '../../steps/data/local_steps_repository.dart';
import '../../steps/domain/local_step.dart';
import '../domain/sync_report.dart';
import '../domain/sync_rules.dart';
import 'sync_api.dart';

/// Automatic runs after a sign-in or a resume start at most this often
/// (plan Q4). Far below the server's 60 requests per 15 minutes.
const Duration automaticRunGap = Duration(minutes: 2);

/// When a 429 came without a usable Retry-After: the server's whole window.
const Duration defaultTooManyWait = Duration(minutes: 15);

/// The longest a run waits for a device key check that is already running
/// (it may include a PUT to a server that is waking up).
const Duration keyCheckWait = Duration(minutes: 2);

/// What the screen shows: whether a run is going, how far it is, and the
/// last run's report.
class SyncStatus {
  const SyncStatus({
    this.running = false,
    this.done = 0,
    this.total = 0,
    this.last,
  });

  final bool running;

  /// Steps answered so far in this run, and how many were due at its start.
  final int done;
  final int total;

  /// The last finished run's report, if any.
  final SyncReport? last;
}

class SyncService extends Notifier<SyncStatus> {
  /// The run in progress; a second trigger gets this same Future.
  Future<SyncReport?>? _running;

  /// When the last automatic run started, for [automaticRunGap].
  DateTime? _lastAutomatic;

  /// No automatic run before this (a 429's Retry-After).
  DateTime? _notBefore;

  Clock get _now => ref.read(clockProvider);

  @override
  SyncStatus build() {
    // A fresh sign-in (including the session restored at start-up) is
    // "app start" (plan Q4). Created in main.dart before restore(), like
    // the device key controller, so it hears that first sign-in.
    final subscription = ref
        .read(signedInEventsProvider)
        .users
        .listen((user) {
          if (signingRoles.contains(user.role)) {
            unawaited(syncNow(SyncTrigger.signIn));
          }
        });
    ref.onDispose(subscription.cancel);

    // Once the session is usable again, "Enter your password" or "You are
    // signed out" from an earlier run is no longer true, so it goes. The
    // send that the fresh sign-in starts (above) then gives a new result.
    ref.listen<AuthState>(authControllerProvider, (previous, next) {
      final last = state.last;
      final staleStop =
          last?.stop == SyncStop.needsPassword ||
          last?.stop == SyncStop.notSignedIn;
      if (next is SignedIn && previous is! SignedIn && staleStop) {
        state = SyncStatus(
          running: state.running,
          done: state.done,
          total: state.total,
        );
      }
    });
    return const SyncStatus();
  }

  /// Starts a run for [trigger], or joins the one already running.
  ///
  /// Returns null when an automatic trigger was not allowed to start one
  /// (within [automaticRunGap], or before a 429's Retry-After).
  Future<SyncReport?> syncNow(SyncTrigger trigger) {
    final running = _running;
    if (running != null) return running;
    if (!_mayStart(trigger)) return Future.value(null);

    final run = _run(trigger).whenComplete(() => _running = null);
    _running = run;
    return run;
  }

  bool _mayStart(SyncTrigger trigger) {
    if (trigger == SyncTrigger.tap) return true; // the user decides
    final now = _now();
    final notBefore = _notBefore;
    if (notBefore != null && now.isBefore(notBefore)) return false;
    // After a save (approved point 7) and after a sign-in (the A57: the
    // send at start stopped for the password, and once the password was
    // entered the 2-minute limit held the next send back) the limit does
    // not apply. A sign-in still counts as the latest automatic run, so a
    // resume straight after it does not send again.
    if (trigger == SyncTrigger.afterSave) return true;
    final last = _lastAutomatic;
    if (trigger != SyncTrigger.signIn &&
        last != null &&
        now.difference(last) < automaticRunGap) {
      return false;
    }
    _lastAutomatic = now;
    return true;
  }

  Future<SyncReport> _run(SyncTrigger trigger) async {
    final stopwatch = Stopwatch()..start();
    final startedAt = _now();
    final manual = trigger == SyncTrigger.tap;
    state = SyncStatus(running: true, last: state.last);

    SyncReport empty() => SyncReport(
      startedAt: startedAt,
      trigger: trigger,
      elapsed: stopwatch.elapsed,
    );

    // Every way out goes through here: the screen stops showing progress,
    // and the counts are read again.
    SyncReport finish(SyncReport report) {
      if (ref.mounted) {
        state = SyncStatus(last: report);
        ref.invalidate(syncCountsProvider);
      }
      return report;
    }

    SyncReport stopped(SyncStop stop, {String? message}) => finish(
      SyncReport(
        startedAt: startedAt,
        trigger: trigger,
        elapsed: stopwatch.elapsed,
        stop: stop,
        message: message,
      ),
    );

    // 2. The session. The token's expiry is compared with the clock here
    // too, so an expired token is never sent (checkExpiry may not have run
    // yet on a resume).
    final auth = ref.read(authControllerProvider);
    if (auth is SignedInNeedsPassword) return stopped(SyncStop.needsPassword);
    if (auth is! SignedIn) return stopped(SyncStop.notSignedIn);
    if (!_now().isBefore(auth.expiresAt)) {
      return stopped(SyncStop.needsPassword);
    }
    final User user = auth.user;
    final String token = auth.token;
    if (!signingRoles.contains(user.role)) return finish(empty());

    // 3. Anything to send? Read before the key or the network, so a run
    // with nothing waiting costs nothing.
    final LocalStepsRepository steps;
    final int total;
    try {
      steps = await ref.read(localStepsRepositoryProvider.future);
      total = await steps.countDue(
        actorId: user.id,
        now: _now(),
        ignoreBackoff: manual,
      );
    } on Object {
      return stopped(SyncStop.savedWorkProblem);
    }
    if (total == 0) return finish(empty());
    if (ref.mounted) {
      state = SyncStatus(running: true, total: total, last: state.last);
    }

    // 4. The device key.
    final keyStop = await _ensureKey(user);
    if (keyStop != null) return stopped(keyStop.$1, message: keyStop.$2);

    final SyncApi api;
    try {
      api = SyncApi(await ref.read(apiClientProvider.future));
    } on Object {
      // PinningSetupError: a certificate file is missing. Fail closed.
      return stopped(SyncStop.insecure);
    }

    // 5 and 6. The batches. The last answer for each step wins (a step
    // deferred for NO_DEVICE_KEY is sent once more after the key PUT).
    final answers = <String, (LocalStep, StepSyncUpdate)>{};
    var unmatched = 0;
    var keyRetried = false;
    SyncCursor? after;

    SyncReport report({SyncStop? stop, String? message}) {
      var sent = 0, underReview = 0, rejected = 0, waiting = 0;
      final problems = <SyncProblem>[];
      for (final (step, update) in answers.values) {
        switch (update) {
          case StepSynced():
            sent++;
          case StepFlagged(:final code, :final message):
            underReview++;
            problems.add(
              SyncProblem(
                qrCode: step.qrCode,
                rejected: false,
                code: code,
                message: message,
              ),
            );
          case StepRejected(:final code, :final message):
            rejected++;
            problems.add(
              SyncProblem(
                qrCode: step.qrCode,
                rejected: true,
                code: code,
                message: message,
              ),
            );
          case StepDeferred():
            waiting++;
        }
      }
      return SyncReport(
        startedAt: startedAt,
        trigger: trigger,
        elapsed: stopwatch.elapsed,
        sent: sent,
        underReview: underReview,
        rejected: rejected,
        waiting: waiting,
        unmatched: unmatched,
        problems: problems,
        stop: stop,
        message: message,
      );
    }

    while (true) {
      final List<LocalStep> batch;
      try {
        batch = await steps.dueForSync(
          actorId: user.id,
          now: _now(),
          ignoreBackoff: manual,
          after: after,
        );
      } on Object {
        return finish(report(stop: SyncStop.savedWorkProblem));
      }
      if (batch.isEmpty) break;

      final List<Object?> results;
      try {
        results = await api.send(token: token, steps: batch);
      } on AppFailure catch (failure) {
        final (stop, message) = _stopFor(failure);
        return finish(report(stop: stop, message: message));
      }

      final at = _now();
      final updates = <StepSyncUpdate>[];
      var needsKey = false;
      for (var i = 0; i < batch.length; i++) {
        var update = i < results.length
            ? updateFromResult(results[i], index: i, sent: batch[i], now: at)
            : null;
        if (update == null) {
          unmatched++;
          continue;
        }
        if (isNoDeviceKey(update) && !keyRetried) {
          // Due again at once, for the retry after the key PUT below.
          final deferred = update as StepDeferred;
          update = StepDeferred(
            deferred.stepId,
            code: deferred.code,
            message: deferred.message,
            nextAttemptAt: at,
          );
          needsKey = true;
        }
        updates.add(update);
        answers[batch[i].stepId] = (batch[i], update);
      }

      try {
        await steps.applyResults(updates, at: at);
      } on Object {
        return finish(report(stop: SyncStop.savedWorkProblem));
      }
      if (ref.mounted) {
        state = SyncStatus(
          running: true,
          done: answers.length.clamp(0, total),
          total: total,
          last: state.last,
        );
      }
      after = SyncCursor.after(batch.last);

      if (needsKey) {
        // The server has no key for this account yet: send it, then go
        // through the queue once more (only once per run).
        keyRetried = true;
        await ref.read(deviceKeyControllerProvider.notifier).check(user);
        after = null;
      }
    }
    return finish(report());
  }

  /// Makes sure the device key may be used (plan §3, step 3). Null when it
  /// can; otherwise why not, and the sentence for a key problem.
  Future<(SyncStop, String?)?> _ensureKey(User user) async {
    var key = ref.read(deviceKeyControllerProvider);
    if (key is DeviceKeyChecking) {
      // A check is already running (it starts with every sign-in): use its
      // answer rather than starting a second one.
      key = await _keyCheckAnswer();
    } else if (key is DeviceKeyUnregistered || key is DeviceKeyNotNeeded) {
      // Not registered yet (or never checked): run the PUT first.
      await ref.read(deviceKeyControllerProvider.notifier).check(user);
      key = ref.read(deviceKeyControllerProvider);
    }
    return switch (key) {
      // Unregistered still (the PUT could not get through): send anyway.
      // The server answers deferred NO_DEVICE_KEY, and nothing is lost.
      DeviceKeyReady() || DeviceKeyUnregistered() => null,
      DeviceKeyOtherDevice() => (SyncStop.keyOtherDevice, null),
      DeviceKeyFailed(:final message) => (SyncStop.keyProblem, message),
      DeviceKeyChecking() ||
      DeviceKeyNotNeeded() => (SyncStop.keyProblem, null),
    };
  }

  Future<DeviceKeyState> _keyCheckAnswer() {
    final answer = Completer<DeviceKeyState>();
    final subscription = ref.listen<DeviceKeyState>(
      deviceKeyControllerProvider,
      (_, next) {
        if (next is! DeviceKeyChecking && !answer.isCompleted) {
          answer.complete(next);
        }
      },
    );
    return answer.future
        .timeout(
          keyCheckWait,
          onTimeout: () => ref.read(deviceKeyControllerProvider),
        )
        .whenComplete(subscription.close);
  }

  /// What a whole-request failure means for the run (plan §3, "Each
  /// answer"). Rows are never changed for any of these.
  (SyncStop, String?) _stopFor(AppFailure failure) {
    switch (failure) {
      case NoConnection():
        return (SyncStop.offline, null);
      case TimedOut():
        return (SyncStop.timedOut, null);
      case InsecureConnection():
        return (SyncStop.insecure, null);
      case BadResponse():
        return (SyncStop.serverProblem, null);
      case ServerRefused(:final status, :final code, :final serverMessage):
        // 401 and 403 session codes were already reported to SessionEvents
        // by ApiClient, and auth reacts (ask for the password, or log out).
        if (code == ApiCodes.tokenExpired) {
          return (SyncStop.needsPassword, null);
        }
        if (SessionEvents.endsSession(status, code)) {
          return (SyncStop.notSignedIn, null);
        }
        if (status == 429) {
          _notBefore = _now().add(failure.retryAfter ?? defaultTooManyWait);
          return (SyncStop.tooManyRequests, serverMessage);
        }
        if (status >= 500) return (SyncStop.serverProblem, null);
        // 400 VALIDATION_FAILED or INVALID_JSON, 413, 403 FORBIDDEN, and
        // anything else: the app sent something the server cannot take.
        return (SyncStop.appProblem, null);
    }
  }
}

/// Kept for the whole run (not autoDispose): it must hear the first
/// sign-in, and a run must not stop because a screen closed.
final syncServiceProvider = NotifierProvider<SyncService, SyncStatus>(
  SyncService.new,
);

/// The signed-in user's steps, counted. Read again after every run and by
/// the screen when it opens.
final syncCountsProvider = FutureProvider.autoDispose<StepCounts>((ref) async {
  final auth = ref.watch(authControllerProvider);
  final user = switch (auth) {
    SignedIn(:final user) || SignedInNeedsPassword(:final user) => user,
    _ => null,
  };
  if (user == null) return const StepCounts();
  final steps = await ref.watch(localStepsRepositoryProvider.future);
  return steps.countsForActor(user.id, now: ref.read(clockProvider)());
});
