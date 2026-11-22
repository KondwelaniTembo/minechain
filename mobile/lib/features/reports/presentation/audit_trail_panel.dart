// The officer's two audit trails (reports plan, T4, Q2; FR-13):
//
// - ConsignmentTrailPanel, on "Check a consignment"'s result: the whole
//   history of the consignment just checked;
// - PersonTrailPanel, on an alert's page: everything the person who recorded
//   the step did in a period, chosen in a small dialog.
//
// Both start from an id the screen already has (the consignment view's, the
// alert actor's): the officer cannot list users. Each has its own slot, so
// its card is its own; the card is shown only for this consignment or this
// person, so a card left over from an earlier one never appears under the
// wrong result.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/status_line.dart';
import '../domain/report_request.dart';
import 'report_download_controller.dart';
import 'report_widgets.dart';

class ConsignmentTrailPanel extends ConsumerWidget {
  const ConsignmentTrailPanel({required this.consignmentId, super.key});

  final String consignmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const slot = ReportSlot.consignmentTrail;
    final state = ref.watch(reportDownloadProvider(slot));
    bool ours(ReportRequest request) =>
        request is ConsignmentAuditTrail &&
        request.consignmentId == consignmentId;
    return _Panel(
      slot: slot,
      state: state,
      ours: ours,
      label: AppText.downloadAuditTrail,
      onPressed: () => ref
          .read(reportDownloadProvider(slot).notifier)
          .download(ConsignmentAuditTrail(consignmentId)),
    );
  }
}

class PersonTrailPanel extends ConsumerWidget {
  const PersonTrailPanel({
    required this.actorId,
    required this.username,
    super.key,
  });

  final String actorId;
  final String username;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const slot = ReportSlot.personTrail;
    final state = ref.watch(reportDownloadProvider(slot));
    bool ours(ReportRequest request) =>
        request is PersonAuditTrail && request.actorId == actorId;
    return _Panel(
      slot: slot,
      state: state,
      ours: ours,
      label: AppText.downloadPersonTrail(username),
      onPressed: () async {
        final period = await showDialog<({DateTime from, DateTime to})>(
          context: context,
          builder: (_) => PersonTrailDialog(username: username),
        );
        if (period == null) return;
        await ref
            .read(reportDownloadProvider(slot).notifier)
            .download(
              PersonAuditTrail(
                actorId: actorId,
                from: period.from,
                to: period.to,
              ),
            );
      },
    );
  }
}

/// The button and, for this panel's own request, the card under it.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.slot,
    required this.state,
    required this.ours,
    required this.label,
    required this.onPressed,
  });

  final ReportSlot slot;
  final ReportDownloadState state;
  final bool Function(ReportRequest) ours;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final request = switch (state) {
      ReportIdle() => null,
      ReportDownloading(:final request) ||
      ReportNeedsPassword(:final request) ||
      ReportFailed(:final request) ||
      ReportReady(:final request) => request,
    };
    final mine = request != null && ours(request);
    final downloading = state is ReportDownloading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: downloading ? null : onPressed,
            icon: downloading && mine
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.history),
            label: Text(downloading && mine ? AppText.downloading : label),
          ),
        ),
        if (mine) ReportStatusCard(slot: slot),
      ],
    );
  }
}

/// "Audit trail of mutale_banda": the period, then Download. Answers the
/// period chosen, or null for Cancel.
class PersonTrailDialog extends ConsumerStatefulWidget {
  const PersonTrailDialog({required this.username, super.key});

  final String username;

  @override
  ConsumerState<PersonTrailDialog> createState() => _PersonTrailDialogState();
}

class _PersonTrailDialogState extends ConsumerState<PersonTrailDialog> {
  late DateTime _from;
  late DateTime _to;

  @override
  void initState() {
    super.initState();
    final period = defaultPeriod(ref.read(clockProvider)());
    _from = period.from;
    _to = period.to;
  }

  @override
  Widget build(BuildContext context) {
    final problem = periodProblem(_from, _to);
    return AlertDialog(
      title: Text(AppText.personTrailTitle(widget.username)),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(AppText.personTrailHint),
          const SizedBox(height: AppSizes.spaceM),
          ReportPeriodButtons(
            from: _from,
            to: _to,
            today: ref.read(clockProvider)().toLocal(),
            onChanged: (from, to) => setState(() {
              _from = from;
              _to = to;
            }),
          ),
          const SizedBox(height: AppSizes.spaceS),
          const Text(AppText.reportUtcNote),
          if (problem != null) ...[
            const SizedBox(height: AppSizes.spaceS),
            StatusLine(
              icon: Icons.error_outline,
              error: true,
              text: periodProblemText(problem),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(AppText.cancel),
        ),
        FilledButton(
          onPressed: problem != null
              ? null
              : () => Navigator.of(context).pop((from: _from, to: _to)),
          child: const Text(AppText.download),
        ),
      ],
    );
  }
}
