// "Take custody" (transporter handoff plan, FR-01, FR-02, FR-07): the
// transporter scans the bag's custody record, sees what the server knows
// about it (or that it could not be checked), and, from T4, weighs it and
// saves a signed handoff. Works offline.
//
// The transporter's view is the blind one (Verification (6)): no weight is
// ever shown here, so the transporter types what their own scale says.
//
// Before the form, the same two gates as registration (SavedWorkGate).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../registration/data/location_source.dart';
import '../../registration/presentation/mineral_chips.dart';
import '../../registration/presentation/mineral_text.dart';
import '../../registration/presentation/qr_scanner_view.dart';
import '../../steps/presentation/saved_work_gate.dart';
import '../../verification/domain/consignment_view.dart';
import '../domain/custody_check.dart';
import 'custody_controller.dart';

class TakeCustodyScreen extends StatelessWidget {
  const TakeCustodyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () => backOrHome(context, AppRoutes.transporter),
        ),
        title: const Text(AppText.takeCustody),
      ),
      body: const SafeArea(
        child: SavedWorkGate(homePath: AppRoutes.transporter, child: _Body()),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(custodyControllerProvider);
    final controller = ref.read(custodyControllerProvider.notifier);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSizes.spaceM),
      child: Center(
        child: ConstrainedBox(
          // A readable width on a phone turned on its side.
          constraints: const BoxConstraints(maxWidth: 560),
          child: switch (state) {
            CustodyScanning(:final notice) => _Scanning(
              notice: notice,
              onCode: controller.onScanned,
            ),
            CustodyChecking(:final qrCode) => _Checking(qrCode: qrCode),
            CustodyReady() => _Ready(form: state, controller: controller),
          },
        ),
      ),
    );
  }
}

// ---- Scanning ----------------------------------------------------------------

class _Scanning extends ConsumerWidget {
  const _Scanning({required this.notice, required this.onCode});
  final ScanNotice? notice;
  final ValueChanged<String> onCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scanner = ref.watch(qrScannerBuilderProvider);
    final text = switch (notice) {
      null => null,
      ScanNotOurs() => AppText.notOurRecord,
      ScanAlreadyTaken(:final on) => AppText.alreadyTookCustody(on.toLocal()),
      ScanPhoneBusy() => AppText.custodyPhoneBusy,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppSizes.tileRadius),
          child: SizedBox(
            height: 260,
            child: scanner(
              onCode: onCode,
              problemBuilder: (context, problem, retry) =>
                  _CameraProblem(problem: problem, retry: retry),
            ),
          ),
        ),
        const SizedBox(height: AppSizes.spaceS),
        const Text(AppText.checkScanHint),
        if (text != null) ...[
          const SizedBox(height: AppSizes.spaceS),
          _StatusLine(icon: Icons.error_outline, error: true, text: text),
        ],
      ],
    );
  }
}

class _Checking extends StatelessWidget {
  const _Checking({required this.qrCode});
  final String qrCode;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A bar, not a spinner: the check can take several seconds.
        const LinearProgressIndicator(),
        const SizedBox(height: AppSizes.spaceM),
        Text(
          AppText.custodyChecking(qrCode),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSizes.spaceS),
        const Text(AppText.checkingTakesTime),
      ],
    );
  }
}

// ---- What is known about the bag ----------------------------------------------

class _Ready extends StatelessWidget {
  const _Ready({required this.form, required this.controller});
  final CustodyReady form;
  final CustodyController controller;

  @override
  Widget build(BuildContext context) {
    final check = form.check;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusLine(
          icon: Icons.check_circle,
          text: AppText.scannedRecord(form.qrCode),
        ),
        const SizedBox(height: AppSizes.spaceS),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: controller.scanAgain,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text(AppText.scanAnother),
          ),
        ),
        const SizedBox(height: AppSizes.spaceM),
        if (check case CustodyChecked(:final view)) ...[
          Text(
            AppText.mineralLine(mineralName(view.mineral)),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(AppText.stageLine(_stageText(view.stage))),
          const SizedBox(height: AppSizes.spaceS),
        ],
        if (check case CustodyUnchecked(:final reason)) ...[
          _StatusLine(
            icon: reason == UncheckedReason.offline
                ? Icons.cloud_off
                : Icons.info_outline,
            text: switch (reason) {
              UncheckedReason.offline => AppText.custodyOffline,
              UncheckedReason.failed => AppText.custodyCheckFailed,
              UncheckedReason.needsPassword =>
                AppText.custodyCheckNeedsPassword,
            },
          ),
          const SizedBox(height: AppSizes.spaceS),
        ],
        for (final warning in form.warnings) ...[
          _StatusLine(
            icon: needsRecordAnyway(warning)
                ? Icons.report_problem
                : Icons.info_outline,
            error: needsRecordAnyway(warning),
            text: switch (warning) {
              CustodyWarning.mismatch => AppText.custodyMismatch,
              CustodyWarning.underReview => AppText.custodyUnderReview,
              CustodyWarning.alreadyBought => AppText.custodyAlreadyBought,
              CustodyWarning.notOnServer => AppText.custodyNotOnServer,
            },
          ),
          const SizedBox(height: AppSizes.spaceS),
        ],
        if (form.waitingForRecordAnyway)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton(
              onPressed: controller.recordAnyway,
              child: const Text(AppText.recordAnyway),
            ),
          )
        else if (form.recordAnyway)
          const _StatusLine(icon: Icons.check, text: AppText.recordingAnyway),
        if (form.choosesMineral && !form.waitingForRecordAnyway) ...[
          const SizedBox(height: AppSizes.spaceM),
          const Text(AppText.chooseMineralFromRecord),
          const SizedBox(height: AppSizes.spaceS),
          MineralChips(
            selected: form.chosenMineral,
            onSelected: controller.chooseMineral,
          ),
        ],
      ],
    );
  }
}

String _stageText(ConsignmentStage stage) => switch (stage) {
  ConsignmentStage.registered => AppText.stageRegistered,
  ConsignmentStage.inTransit => AppText.stageInTransit,
  ConsignmentStage.purchased => AppText.stagePurchased,
};

// ---- Small parts ---------------------------------------------------------------

class _CameraProblem extends ConsumerWidget {
  const _CameraProblem({required this.problem, required this.retry});
  final ScannerProblem problem;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSizes.spaceM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusLine(
              icon: Icons.no_photography,
              error: true,
              text: switch (problem) {
                ScannerProblem.permissionDenied => AppText.cameraNeeded,
                ScannerProblem.noCamera => AppText.noCamera,
                ScannerProblem.failed => AppText.cameraFailed,
              },
            ),
            if (problem != ScannerProblem.noCamera) ...[
              const SizedBox(height: AppSizes.spaceS),
              Wrap(
                spacing: AppSizes.spaceS,
                runSpacing: AppSizes.spaceS,
                children: [
                  FilledButton(
                    onPressed: retry,
                    child: Text(
                      problem == ScannerProblem.permissionDenied
                          ? AppText.allowCamera
                          : AppText.tryAgain,
                    ),
                  ),
                  // Android stops showing the dialog after repeated
                  // refusals; then only the app's settings page can allow it.
                  if (problem == ScannerProblem.permissionDenied)
                    OutlinedButton(
                      onPressed: () =>
                          ref.read(locationSourceProvider).openAppSettings(),
                      child: const Text(AppText.openSettings),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.text,
    this.error = false,
  });
  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colour = error ? scheme.error : scheme.onSurface;
    // A live region: TalkBack reads a warning out when it appears.
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Icon(icon, color: colour)),
          const SizedBox(width: AppSizes.spaceS),
          Expanded(
            child: Text(text, style: TextStyle(color: colour)),
          ),
        ],
      ),
    );
  }
}
