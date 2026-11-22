// "Reports" (reports plan, T3, §4.1): the transactions report (FR-09) for
// the officer, the buyer and the administrator, at /officer/reports,
// /buyer/reports and /admin/reports.
//
// Choose a period and the filters, then "Download and share": the file is
// written to the app's cache and the share sheet opens (Q6). The form keeps
// its choices after a failure; changing one clears the failure (T5b). A buyer has no review filter: their file only
// ever holds accepted steps, so the server would answer "Flagged" with an
// empty file.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/status_line.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/domain/user.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../registration/domain/mineral.dart';
import '../../registration/presentation/mineral_text.dart';
import '../../verification/domain/consignment_view.dart'
    show AnchorStatus, ReviewStatus, StepType;
import '../domain/report_request.dart';
import 'report_download_controller.dart';
import 'report_widgets.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  late DateTime _from;
  late DateTime _to;
  Mineral? _mineral;
  StepType? _type;
  ReviewStatus? _review;
  AnchorStatus? _anchor;

  @override
  void initState() {
    super.initState();
    final period = defaultPeriod(ref.read(clockProvider)());
    _from = period.from;
    _to = period.to;
  }

  bool get _isBuyer => switch (ref.watch(authControllerProvider)) {
    SignedIn(:final user) ||
    SignedInNeedsPassword(:final user) => user.role == Role.buyer,
    _ => false,
  };

  TransactionsReport _request({required bool buyer}) => TransactionsReport(
    from: _from,
    to: _to,
    mineral: _mineral,
    type: _type,
    reviewStatus: buyer ? null : _review,
    anchorStatus: _anchor,
  );

  /// A new choice in the form. A failure's card goes with it (T5b): its
  /// "Try again" would send the old choices.
  void _change(VoidCallback choice) {
    setState(choice);
    ref
        .read(reportDownloadProvider(ReportSlot.transactions).notifier)
        .forgetFailure();
  }

  @override
  Widget build(BuildContext context) {
    const slot = ReportSlot.transactions;
    final downloading =
        ref.watch(reportDownloadProvider(slot)) is ReportDownloading;
    final buyer = _isBuyer;
    final request = _request(buyer: buyer);
    final problem = request.problem;
    final enabled = !downloading;

    return Scaffold(
      appBar: AppBar(title: const Text(AppText.reports)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          child: Center(
            child: ConstrainedBox(
              // A readable width on a phone turned on its side.
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(AppText.reportsIntro),
                  if (buyer) ...[
                    const SizedBox(height: AppSizes.spaceS),
                    const Text(AppText.reportsBuyerNote),
                  ],
                  const SizedBox(height: AppSizes.spaceL),
                  Text(
                    AppText.reportPeriod,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSizes.spaceS),
                  ReportPeriodButtons(
                    from: _from,
                    to: _to,
                    today: ref.read(clockProvider)().toLocal(),
                    enabled: enabled,
                    onChanged: (from, to) => _change(() {
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
                  const SizedBox(height: AppSizes.spaceL),
                  ReportFilterChips<Mineral>(
                    label: AppText.filterMineral,
                    choices: {
                      for (final m in Mineral.values) m: mineralName(m),
                    },
                    selected: _mineral,
                    enabled: enabled,
                    onSelected: (m) => _change(() => _mineral = m),
                  ),
                  const SizedBox(height: AppSizes.spaceM),
                  ReportFilterChips<StepType>(
                    label: AppText.filterStep,
                    choices: const {
                      StepType.registration: AppText.stepRegistrations,
                      StepType.handoff: AppText.stepHandoffs,
                      StepType.purchase: AppText.stepPurchases,
                    },
                    selected: _type,
                    enabled: enabled,
                    onSelected: (t) => _change(() => _type = t),
                  ),
                  if (!buyer) ...[
                    const SizedBox(height: AppSizes.spaceM),
                    ReportFilterChips<ReviewStatus>(
                      label: AppText.filterReview,
                      choices: const {
                        ReviewStatus.passed: AppText.filterReviewPassed,
                        ReviewStatus.flagged: AppText.filterReviewFlagged,
                        ReviewStatus.cleared: AppText.filterReviewCleared,
                        ReviewStatus.rejected: AppText.filterReviewRejected,
                      },
                      selected: _review,
                      enabled: enabled,
                      onSelected: (r) => _change(() => _review = r),
                    ),
                  ],
                  const SizedBox(height: AppSizes.spaceM),
                  ReportFilterChips<AnchorStatus>(
                    label: AppText.filterChain,
                    choices: const {
                      AnchorStatus.pending: AppText.chainWaiting,
                      AnchorStatus.submitted: AppText.chainSent,
                      AnchorStatus.confirmed: AppText.chainConfirmed,
                      AnchorStatus.failed: AppText.chainFailed,
                    },
                    selected: _anchor,
                    enabled: enabled,
                    onSelected: (a) => _change(() => _anchor = a),
                  ),
                  const SizedBox(height: AppSizes.spaceL),
                  BusyButton(
                    label: AppText.downloadAndShare,
                    busyLabel: AppText.downloading,
                    busy: downloading,
                    onPressed: problem != null
                        ? () {} // the period's sentence above says why
                        : () => ref
                              .read(reportDownloadProvider(slot).notifier)
                              .download(request),
                  ),
                  const ReportStatusCard(slot: slot),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
