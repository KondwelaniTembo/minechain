// "Send my work" (plan M6): what is waiting on this phone, a Send button,
// the progress of a send, and what the sends came to.
//
// The counts come from the database itself, so "safe on this phone" is
// only said when the rows are really there (plan §3). The sends' result is
// the sync service's, so a send started by a save or a resume is shown here
// too. Since T5b it sums up every send since the user last looked (two
// saves in a row are two sends), and leaving the screen forgets that sum.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/database_failure.dart';
import '../../../core/errors/api_codes.dart';
import '../../../core/router/redirect.dart';
import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/password_prompt.dart';
import '../../steps/domain/local_step.dart';
import '../data/sync_service.dart';
import '../domain/sync_report.dart';

class SendWorkScreen extends ConsumerStatefulWidget {
  const SendWorkScreen({super.key});

  @override
  ConsumerState<SendWorkScreen> createState() => _SendWorkScreenState();
}

class _SendWorkScreenState extends ConsumerState<SendWorkScreen> {
  // Read in initState: ref may not be used in dispose.
  late final SyncService _sync;

  @override
  void initState() {
    super.initState();
    _sync = ref.read(syncServiceProvider.notifier);
  }

  @override
  void dispose() {
    // However the screen is left (back arrow, Android back, the navigation
    // bar): the user has seen these sends. After this frame, because a
    // provider may not change while widgets are being taken down.
    final sync = _sync;
    Future.microtask(sync.clearSummary);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final counts = ref.watch(syncCountsProvider);
    final status = ref.watch(syncServiceProvider);
    final summary =
        status.summary ??
        switch (status.last) {
          // Nothing new since the screen was last left: the last send, as
          // before T5b, so the screen does not go blank.
          final SyncReport last => SyncSummary.of(last),
          null => null,
        };

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => _back(context, ref)),
        title: const Text(AppText.sendMyWork),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Counts(counts),
                  // 32 dp, the same as before the lines lost their own 8 dp
                  // below (the last one's 8 plus 24 here).
                  const SizedBox(height: AppSizes.spaceXl),
                  FilledButton.icon(
                    onPressed: status.running
                        ? null
                        : () => _send(context, ref),
                    icon: const Icon(Icons.cloud_upload),
                    label: Text(
                      status.running ? AppText.sendingNow : AppText.sendNow,
                    ),
                  ),
                  const SizedBox(height: AppSizes.spaceM),
                  if (status.running)
                    _Progress(status)
                  else if (summary != null)
                    _Sends(summary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Back to the screen below, or to the signed-in user's own home when there
/// is none: the screen serves miners and transporters (T5).
void _back(BuildContext context, WidgetRef ref) {
  if (context.canPop()) {
    context.pop();
    return;
  }
  final home = switch (ref.read(authControllerProvider)) {
    SignedIn(:final user) ||
    SignedInNeedsPassword(:final user) => homeOf(user.role),
    _ => AppRoutes.login,
  };
  context.go(home);
}

/// A tap on Send: ask for the password first if the session needs it
/// (plan §3, step 2), then send, ignoring the backoff.
Future<void> _send(BuildContext context, WidgetRef ref) async {
  await ref.read(authControllerProvider.notifier).checkExpiry();
  if (!context.mounted) return;
  if (ref.read(authControllerProvider) is SignedInNeedsPassword &&
      !await showPasswordPrompt(context)) {
    return; // cancelled: nothing is sent, nothing is lost
  }
  if (!context.mounted) return;
  await ref.read(syncServiceProvider.notifier).syncNow(SyncTrigger.tap);
}

/// An icon and a sentence, never colour alone.
class _Line extends StatelessWidget {
  const _Line(this.icon, this.text, {this.error = false});
  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? Theme.of(context).colorScheme.error : null;
    // No space below: _Counts puts the gaps between lines, so a line shown
    // on its own (the counts cannot be read yet) has none.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(child: Icon(icon, color: color)),
        const SizedBox(width: AppSizes.spaceS),
        Expanded(
          child: Text(text, style: TextStyle(color: color)),
        ),
      ],
    );
  }
}

class _Counts extends StatelessWidget {
  const _Counts(this.counts);
  final AsyncValue<StepCounts> counts;

  static const double lineGap = AppSizes.spaceM;

  @override
  Widget build(BuildContext context) {
    // While the counts are read again after a send, the old ones stay.
    if (counts.hasValue) {
      final c = counts.requireValue;
      final lines = <Widget>[
        _Line(
          c.waiting > 0 ? Icons.phone_android : Icons.check_circle,
          c.waiting > 0
              ? AppText.waitingOnPhone(c.waiting)
              : AppText.nothingWaiting,
        ),
        _Line(Icons.cloud_done, AppText.countSentToServer(c.sentToServer)),
        // Indented: part of the line above, not more records.
        Padding(
          padding: const EdgeInsetsDirectional.only(start: AppSizes.spaceL),
          child: _Line(
            Icons.policy,
            AppText.countOfWhichUnderReview(c.underReview),
          ),
        ),
        _Line(
          Icons.report_problem,
          AppText.countNeedsAttention(c.needsAttention),
          error: c.needsAttention > 0,
        ),
        if (c.stuck > 0)
          const _Line(Icons.schedule, AppText.stuckDeferred, error: true),
      ];
      return Semantics(
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < lines.length; i++) ...[
              // 16 dp between lines, so each count reads as its own line
              // on the phone (Mobile (36), T9; it was 8 dp).
              if (i > 0) const SizedBox(height: lineGap),
              lines[i],
            ],
          ],
        ),
      );
    }
    if (counts.hasError) {
      // "Cannot be opened" only when it really cannot; a busy moment is
      // calm (the counts are read again after the next send).
      if (savedWorkUnreadable(counts.error!)) {
        return const _Line(
          Icons.storage,
          AppText.savedWorkProblem,
          error: true,
        );
      }
      return const _Line(Icons.hourglass_empty, AppText.countsPhoneBusy);
    }
    return const _Line(Icons.hourglass_empty, AppText.openingSavedWork);
  }
}

class _Progress extends StatelessWidget {
  const _Progress(this.status);
  final SyncStatus status;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      LinearProgressIndicator(
        // Unknown until the due steps are counted; then the share answered.
        value: status.total == 0 ? null : status.done / status.total,
      ),
      const SizedBox(height: AppSizes.spaceS),
      Semantics(
        liveRegion: true,
        child: Text(
          status.total == 0
              ? AppText.sendingNow
              : AppText.sendingProgress(status.done, status.total),
        ),
      ),
      const SizedBox(height: AppSizes.spaceS),
      const Text(AppText.sendingSlowServer),
    ],
  );
}

class _Sends extends StatelessWidget {
  const _Sends(this.summary);
  final SyncSummary summary;

  @override
  Widget build(BuildContext context) {
    final report = summary.combined;
    final stop = report.stop;
    // The phone's own time: the user reads it against their watch.
    final startedAt = report.startedAt.toLocal();
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            summary.sends == 1
                ? AppText.lastSendAt(startedAt, _whyText(report.trigger))
                : AppText.sendsSince(
                    startedAt,
                    summary.sends,
                    summary.sameTrigger ? _whyText(report.trigger) : null,
                  ),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSizes.spaceS),
          if (report.nothingToSend)
            const _Line(Icons.check_circle, AppText.nothingToSend),
          if (report.sentToServer > 0)
            _Line(
              Icons.cloud_done,
              AppText.resultSentToServer(
                report.sentToServer,
                underReview: report.underReview,
              ),
            ),
          if (report.rejected > 0)
            _Line(
              Icons.block,
              AppText.resultRejected(report.rejected),
              error: true,
            ),
          if (report.waiting > 0)
            _Line(Icons.schedule, AppText.resultWaiting(report.waiting)),
          for (final problem in report.problems)
            _Line(
              problem.rejected ? Icons.block : Icons.policy,
              _problemText(problem),
              error: problem.rejected,
            ),
          if (report.unmatched > 0)
            const _Line(
              Icons.report_problem,
              AppText.unmatchedAnswers,
              error: true,
            ),
          if (stop == SyncStop.phoneBusy)
            // Calm, not an error: nothing is wrong with the work.
            _Line(
              Icons.schedule,
              report.retrySoon
                  ? AppText.notSentPhoneBusy
                  : AppText.notSentPhoneBusyTryAgain,
            )
          else if (stop != null)
            _Line(
              Icons.cloud_off,
              _stopText(stop, report.message),
              error: true,
            ),
          // For measuring NFR-03 ("sync within 10 s") on the A57. Debug
          // builds only, and never logged.
          if (kDebugMode && !report.nothingToSend)
            _Line(Icons.timer, AppText.sendTook(report.elapsed)),
        ],
      ),
    );
  }
}

String _whyText(SyncTrigger trigger) => switch (trigger) {
  SyncTrigger.tap => AppText.sendYouTapped,
  SyncTrigger.afterSave => AppText.sendAfterSave,
  SyncTrigger.signIn || SyncTrigger.resume => AppText.sendAutomatic,
};

String _problemText(SyncProblem problem) {
  if (!problem.rejected) {
    return AppText.underReviewLine(problem.qrCode, problem.message);
  }
  if (problem.code == ApiCodes.payloadUnsupportedVersion) {
    return AppText.updateAppLine(problem.qrCode);
  }
  return AppText.rejectedLine(problem.qrCode, problem.code);
}

String _stopText(SyncStop stop, String? message) => switch (stop) {
  SyncStop.offline => AppText.notSentOffline,
  SyncStop.timedOut => AppText.notSentTimedOut,
  SyncStop.serverProblem => AppText.notSentServer,
  SyncStop.tooManyRequests => message ?? AppText.tooManyTries,
  SyncStop.appProblem => AppText.notSentAppProblem,
  SyncStop.insecure => AppText.insecureConnection,
  SyncStop.savedWorkProblem => AppText.savedWorkProblem,
  SyncStop.phoneBusy => AppText.notSentPhoneBusy, // shown above, calmly
  SyncStop.needsPassword => AppText.notSentNeedsPassword,
  SyncStop.notSignedIn => AppText.notSentSignedOut,
  SyncStop.keyOtherDevice => AppText.deviceKeyOtherDevice,
  SyncStop.keyProblem => message ?? AppText.notSentKeyProblem,
};
