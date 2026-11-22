// The pieces every report download shows (reports plan, T3 and T4): the
// period buttons, the filter chips, and the card under the button that says
// how the download and its share went.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/status_line.dart';
import '../../auth/presentation/password_prompt.dart';
import '../data/report_file_store.dart';
import '../domain/report_request.dart';
import 'report_download_controller.dart';

/// The sentence for a failed download.
///
/// 429 keeps the server's words ("Too many report downloads…"): the app's
/// shared sentence for TOO_MANY_REQUESTS is about login tries. The two
/// not-found codes get report words: the shared USER_NOT_FOUND sentence
/// sends the administrator back to a list. A VALIDATION_FAILED here can only
/// be the period (the app checks it first, so the server's rule changed).
String reportFailureText(Exception failure) {
  return switch (failure) {
    ServerRefused(code: ApiCodes.tooManyRequests, :final serverMessage)
        when serverMessage.trim().isNotEmpty =>
      serverMessage,
    ServerRefused(code: ApiCodes.userNotFound) => AppText.reportPersonNotFound,
    ServerRefused(code: ApiCodes.consignmentNotFound) =>
      AppText.reportConsignmentNotFound,
    ServerRefused(code: ApiCodes.validationFailed) =>
      AppText.reportPeriodRefused,
    AppFailure() => failureText(failure),
    ReportNotSaved() => AppText.reportNotSaved,
    _ => AppText.somethingWentWrong,
  };
}

/// Whether "Try again" with the same request can help. A 4xx refusal (too
/// large, not found, too many downloads) will be the same answer again.
bool _worthRetrying(Exception failure) => switch (failure) {
  ServerRefused(:final status) => status >= 500,
  InsecureConnection() => false,
  NoConnection() || TimedOut() || BadResponse() => true,
  _ => true, // ReportNotSaved: space may have been freed
};

/// The sentence for a period problem.
String periodProblemText(PeriodProblem problem) => switch (problem) {
  PeriodProblem.toBeforeFrom => AppText.periodToBeforeFrom,
  PeriodProblem.tooLong => AppText.periodTooLong,
};

/// "From 1 Nov 2026" and "To 30 Nov 2026": either opens the range picker.
class ReportPeriodButtons extends StatelessWidget {
  const ReportPeriodButtons({
    required this.from,
    required this.to,
    required this.onChanged,
    required this.today,
    this.enabled = true,
    super.key,
  });

  /// UTC midnights (reportDay).
  final DateTime from;
  final DateTime to;
  final void Function(DateTime from, DateTime to) onChanged;

  /// The last day that can be picked (the phone's own today).
  final DateTime today;
  final bool enabled;

  Future<void> _pick(BuildContext context) async {
    // The picker works in local dates; only the calendar day is kept.
    final last = DateTime(today.year, today.month, today.day);
    DateTime local(DateTime d) => DateTime(d.year, d.month, d.day);
    DateTime clamp(DateTime d) => d.isAfter(last) ? last : d;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2025),
      lastDate: last,
      initialDateRange: DateTimeRange(
        start: clamp(local(from)),
        end: clamp(local(to)),
      ),
      helpText: AppText.reportPickPeriod,
    );
    if (picked != null) {
      onChanged(reportDay(picked.start), reportDay(picked.end));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSizes.spaceS,
      runSpacing: AppSizes.spaceS,
      children: [
        OutlinedButton.icon(
          onPressed: enabled ? () => _pick(context) : null,
          icon: const Icon(Icons.date_range),
          label: Text(AppText.reportFrom(from)),
        ),
        OutlinedButton.icon(
          onPressed: enabled ? () => _pick(context) : null,
          icon: const Icon(Icons.event),
          label: Text(AppText.reportTo(to)),
        ),
      ],
    );
  }
}

/// A filter: "Any" first, then each choice. Null is "Any".
class ReportFilterChips<T extends Object> extends StatelessWidget {
  const ReportFilterChips({
    required this.label,
    required this.choices,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  final String label;

  /// Each choice and its words, in the order shown.
  final Map<T, String> choices;
  final T? selected;
  final ValueChanged<T?> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    Widget chip(T? value, String words) => ConstrainedBox(
      // The app's 56 dp minimum (gloves, dusty fingers), as MineralChips.
      constraints: const BoxConstraints(minHeight: AppSizes.tapTargetMin),
      child: ChoiceChip(
        label: Text(words),
        selected: selected == value,
        onSelected: enabled ? (_) => onSelected(value) : null,
      ),
    );
    return Semantics(
      container: true,
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSizes.spaceS),
          Wrap(
            spacing: AppSizes.spaceS,
            runSpacing: AppSizes.spaceS,
            children: [
              chip(null, AppText.filterAny),
              for (final entry in choices.entries) chip(entry.key, entry.value),
            ],
          ),
        ],
      ),
    );
  }
}

/// How the download in [slot] went: nothing yet, under way, the password
/// needed, failed, or the file with its share line and "Share again".
/// The download's card. It scrolls itself into view when a new kind of
/// card appears (the bar, a failure, the password, the file; T5b): on a
/// phone it sits below the button, and the phone check found "No internet
/// connection" and "Share again" out of sight, so the button seemed to do
/// nothing. The share line changing does not move the page.
class ReportStatusCard extends ConsumerStatefulWidget {
  const ReportStatusCard({required this.slot, super.key});

  final ReportSlot slot;

  @override
  ConsumerState<ReportStatusCard> createState() => _ReportStatusCardState();
}

class _ReportStatusCardState extends ConsumerState<ReportStatusCard> {
  @override
  void initState() {
    super.initState();
    // An audit-trail card is only built once its download has started.
    if (ref.read(reportDownloadProvider(widget.slot)) is! ReportIdle) {
      _reveal();
    }
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        // As little scrolling as shows the whole card, the button above it
        // stays in sight where it fits.
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final slot = widget.slot;
    ref.listen(reportDownloadProvider(slot), (previous, next) {
      if (next is ReportIdle) return;
      if (previous != null && previous.runtimeType == next.runtimeType) return;
      _reveal();
    });
    final state = ref.watch(reportDownloadProvider(slot));
    final controller = ref.read(reportDownloadProvider(slot).notifier);
    final Widget? body = switch (state) {
      ReportIdle() => null,
      // A bar, not a spinner: a long report can take a minute on 3G.
      ReportDownloading() => const LinearProgressIndicator(),
      ReportNeedsPassword() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StatusLine(
            icon: Icons.lock_clock,
            text: AppText.reportNeedsPassword,
          ),
          const SizedBox(height: AppSizes.spaceS),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: () async {
                if (await showPasswordPrompt(context)) {
                  await controller.retry();
                }
              },
              child: const Text(AppText.enterPasswordButton),
            ),
          ),
        ],
      ),
      ReportFailed(:final failure) => _FailedBody(
        failure: failure,
        onRetry: controller.retry,
      ),
      ReportReady(:final report, :final share) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.description_outlined),
              const SizedBox(width: AppSizes.spaceS),
              Expanded(
                child: Text(
                  report.filename,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSizes.spaceS),
          Text(AppText.reportRows(report.rows)),
          Text(AppText.reportDownloadedAt(report.downloadedAt.toLocal())),
          if (_shareLine(share) case final line?) ...[
            const SizedBox(height: AppSizes.spaceS),
            StatusLine(
              icon: share == ShareStatus.failed
                  ? Icons.error_outline
                  : Icons.share,
              error: share == ShareStatus.failed,
              text: line,
            ),
          ],
          const SizedBox(height: AppSizes.spaceS),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: share == ShareStatus.opening
                  ? null
                  : controller.shareAgain,
              icon: const Icon(Icons.share),
              label: const Text(AppText.shareAgain),
            ),
          ),
        ],
      ),
    };
    if (body == null) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(top: AppSizes.spaceM),
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.spaceM),
        child: body,
      ),
    );
  }

  static String? _shareLine(ShareStatus share) => switch (share) {
    ShareStatus.opening => AppText.reportOpeningShare,
    ShareStatus.shared => AppText.reportShared,
    ShareStatus.notShared => AppText.reportNotShared,
    ShareStatus.failed => AppText.reportShareFailed,
    ShareStatus.unknown => null,
  };
}

class _FailedBody extends StatelessWidget {
  const _FailedBody({required this.failure, required this.onRetry});
  final Exception failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final wait = failure is ServerRefused
        ? (failure as ServerRefused).retryAfter
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusLine(
          icon: Icons.error_outline,
          error: true,
          text: reportFailureText(failure),
        ),
        if (wait != null) ...[
          const SizedBox(height: AppSizes.spaceS),
          Text(AppText.reportTryAgainIn(wait)),
        ],
        if (_worthRetrying(failure)) ...[
          const SizedBox(height: AppSizes.spaceS),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: onRetry,
              child: const Text(AppText.tryAgain),
            ),
          ),
        ],
      ],
    );
  }
}
