// "Take custody" (transporter handoff plan, FR-01, FR-02, FR-07): the
// transporter scans the bag's custody record, sees what the server knows
// about it (or that it could not be checked), weighs it on their own scale
// and saves a signed handoff with their place and time (T4). Works offline:
// the handoff is kept on the phone and sent when there is a network.
//
// The transporter's view is the blind one (Verification (6)): no weight is
// ever shown here, so the transporter types what their own scale says.
//
// "Record purchase" (buyer purchase plan, T2) is this page for the buyer,
// with kind: CustodyStepKind.purchase. The words, the home, the warnings
// and the save differ (see _KindWords); the flow is the same. The buyer is
// not shown earlier weights either (Q1), although the server would send
// them: their figure is their own measurement, so the 10% rule stays a real
// comparison.
//
// Before the form, the same two gates as registration (SavedWorkGate).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/form_message.dart';
import '../../../core/widgets/status_line.dart';
import '../../registration/data/location_source.dart';
import '../../registration/presentation/mineral_chips.dart';
import '../../registration/presentation/mineral_text.dart';
import '../../registration/presentation/qr_scanner_view.dart';
import '../../steps/presentation/location_status_view.dart';
import '../../steps/presentation/saved_view.dart';
import '../../steps/presentation/saved_work_gate.dart';
import '../../steps/presentation/weight_field.dart';
import '../data/record_handoff.dart';
import '../../verification/domain/consignment_view.dart';
import '../domain/custody_check.dart';
import 'custody_controller.dart';

class TakeCustodyScreen extends StatelessWidget {
  const TakeCustodyScreen({this.kind = CustodyStepKind.handoff, super.key});

  /// Take custody (a handoff) or Record purchase.
  final CustodyStepKind kind;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => backOrHome(context, kind.home)),
        title: Text(kind.title),
      ),
      body: SafeArea(
        child: SavedWorkGate(
          homePath: kind.home,
          child: _Body(kind: kind),
        ),
      ),
    );
  }
}

/// What the page says and where it goes back to, by kind.
extension _KindWords on CustodyStepKind {
  String get title => switch (this) {
    CustodyStepKind.handoff => AppText.takeCustody,
    CustodyStepKind.purchase => AppText.recordPurchase,
  };

  String get home => switch (this) {
    CustodyStepKind.handoff => AppRoutes.transporter,
    CustodyStepKind.purchase => AppRoutes.buyer,
  };

  String get anotherLabel => switch (this) {
    CustodyStepKind.handoff => AppText.takeAnotherCustody,
    CustodyStepKind.purchase => AppText.recordAnotherPurchase,
  };

  /// Q4: already recorded on this phone, in the phone's own time.
  String alreadyRecorded(DateTime localTime) => switch (this) {
    CustodyStepKind.handoff => AppText.alreadyTookCustody(localTime),
    CustodyStepKind.purchase => AppText.alreadyBoughtHere(localTime),
  };

  String warning(CustodyWarning warning) => switch ((this, warning)) {
    (CustodyStepKind.handoff, CustodyWarning.mismatch) =>
      AppText.custodyMismatch,
    (CustodyStepKind.handoff, CustodyWarning.underReview) =>
      AppText.custodyUnderReview,
    (CustodyStepKind.handoff, CustodyWarning.alreadyBought) =>
      AppText.custodyAlreadyBought,
    (CustodyStepKind.handoff, CustodyWarning.notOnServer) =>
      AppText.custodyNotOnServer,
    (CustodyStepKind.purchase, CustodyWarning.mismatch) =>
      AppText.purchaseMismatch,
    (CustodyStepKind.purchase, CustodyWarning.underReview) =>
      AppText.purchaseUnderReview,
    (CustodyStepKind.purchase, CustodyWarning.alreadyBought) =>
      AppText.purchaseAlreadyBought,
    (CustodyStepKind.purchase, CustodyWarning.notOnServer) =>
      AppText.purchaseNotOnServer,
  };
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.kind});
  final CustodyStepKind kind;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> with WidgetsBindingObserver {
  final _weight = TextEditingController();
  final _weightFocus = FocusNode();

  /// Whether the weight's format problems are shown: not while typing, but
  /// when the field is left or the greyed-out Save is tapped, as on the
  /// registration screen.
  bool _showWeightProblems = false;

  @override
  void initState() {
    super.initState();
    // To try the location again when the user comes back from the phone's
    // settings page.
    WidgetsBinding.instance.addObserver(this);
    _weightFocus.addListener(_onWeightFocus);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _weightFocus
      ..removeListener(_onWeightFocus)
      ..dispose();
    _weight.dispose();
    super.dispose();
  }

  void _onWeightFocus() {
    if (!_weightFocus.hasFocus) _revealWeightProblems();
  }

  void _revealWeightProblems() {
    if (mounted && !_showWeightProblems) {
      setState(() => _showWeightProblems = true);
    }
  }

  NotifierProvider<CustodyController, CustodyState> get _provider =>
      custodyControllerFor(widget.kind);

  void _weightEdited(String text) {
    ref.read(_provider.notifier).weightChanged(text);
    if (_showWeightProblems) setState(() => _showWeightProblems = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final controller = ref.read(_provider.notifier);
    // ask: false, as on registration: closing any permission dialog also
    // "resumes" the app, and only the buttons may ask.
    if (controller.locationBlocked) controller.startLocation(ask: false);
  }

  @override
  Widget build(BuildContext context) {
    // Each bag starts with an empty weight field.
    final kind = widget.kind;
    ref.listen(_provider, (previous, next) {
      if (next is! CustodyReady) {
        _weight.clear();
        _showWeightProblems = false;
      }
    });
    final state = ref.watch(_provider);
    final controller = ref.read(_provider.notifier);

    if (state case CustodyReady(saved: true, :final saveDuration)) {
      return SavedView(
        duration: saveDuration,
        anotherLabel: kind.anotherLabel,
        savedThisVisit: controller.savesThisVisit,
        onAnother: controller.scanAgain,
        onHome: () => backOrHome(context, kind.home),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSizes.spaceM),
      child: Center(
        child: ConstrainedBox(
          // A readable width on a phone turned on its side.
          constraints: const BoxConstraints(maxWidth: 560),
          child: switch (state) {
            CustodyScanning(:final notice) => _Scanning(
              kind: kind,
              notice: notice,
              onCode: controller.onScanned,
            ),
            CustodyChecking(:final qrCode) => _Checking(qrCode: qrCode),
            CustodyReady() => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Ready(form: state, controller: controller),
                if (state.mayContinue)
                  _WeighAndSave(
                    form: state,
                    controller: controller,
                    weight: _weight,
                    weightFocus: _weightFocus,
                    showWeightProblems: _showWeightProblems,
                    onWeightChanged: _weightEdited,
                    onDisabledSaveTap: _revealWeightProblems,
                  ),
              ],
            ),
          },
        ),
      ),
    );
  }
}

// ---- Scanning ----------------------------------------------------------------

class _Scanning extends ConsumerWidget {
  const _Scanning({
    required this.kind,
    required this.notice,
    required this.onCode,
  });
  final CustodyStepKind kind;
  final ScanNotice? notice;
  final ValueChanged<String> onCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scanner = ref.watch(qrScannerBuilderProvider);
    final text = switch (notice) {
      null => null,
      ScanNotOurs() => AppText.notOurRecord,
      ScanAlreadyTaken(:final on) => kind.alreadyRecorded(on.toLocal()),
      ScanBoughtByYou(:final on) => AppText.boughtByYou(on.toLocal()),
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
          StatusLine(icon: Icons.error_outline, error: true, text: text),
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
        StatusLine(
          icon: Icons.check_circle,
          text: AppText.scannedRecord(form.qrCode),
        ),
        const SizedBox(height: AppSizes.spaceS),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: form.saving ? null : controller.scanAgain,
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
          StatusLine(
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
          StatusLine(
            icon: needsRecordAnyway(warning, form.kind)
                ? Icons.report_problem
                : Icons.info_outline,
            error: needsRecordAnyway(warning, form.kind),
            text: form.kind.warning(warning),
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
          const StatusLine(icon: Icons.check, text: AppText.recordingAnyway),
        if (form.choosesMineral && !form.waitingForRecordAnyway) ...[
          const SizedBox(height: AppSizes.spaceM),
          const Text(AppText.chooseMineralFromRecord),
          const SizedBox(height: AppSizes.spaceS),
          MineralChips(
            selected: form.chosenMineral,
            enabled: form.editable,
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

// ---- Weigh and save (T4) -------------------------------------------------------

class _WeighAndSave extends StatelessWidget {
  const _WeighAndSave({
    required this.form,
    required this.controller,
    required this.weight,
    required this.weightFocus,
    required this.showWeightProblems,
    required this.onWeightChanged,
    required this.onDisabledSaveTap,
  });

  final CustodyReady form;
  final CustodyController controller;
  final TextEditingController weight;
  final FocusNode weightFocus;
  final bool showWeightProblems;
  final ValueChanged<String> onWeightChanged;
  final VoidCallback onDisabledSaveTap;

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSizes.spaceL),
        Text(AppText.handoffLocationStep, style: title),
        const SizedBox(height: AppSizes.spaceS),
        LocationStatusView(
          status: form.location,
          onStart: controller.startLocation,
          onOpenLocationSettings: controller.openLocationSettings,
          onOpenAppSettings: controller.openAppSettings,
        ),
        const SizedBox(height: AppSizes.spaceL),
        Text(AppText.handoffWeightStep, style: title),
        const SizedBox(height: AppSizes.spaceS),
        const Text(AppText.handoffWeightHint),
        const SizedBox(height: AppSizes.spaceS),
        WeightField(
          unit: form.mineral?.unit,
          controller: weight,
          focus: weightFocus,
          enabled: !form.saving,
          showProblems: showWeightProblems,
          onChanged: onWeightChanged,
        ),
        const SizedBox(height: AppSizes.spaceL),
        // A disabled button ignores taps, so this catches a tap on the
        // greyed-out Save and shows why it cannot save yet.
        GestureDetector(
          onTap: form.canSave ? null : onDisabledSaveTap,
          child: FilledButton.icon(
            onPressed: form.canSave ? controller.save : null,
            icon: form.saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: Text(form.saving ? AppText.saving : AppText.save),
          ),
        ),
        if (form.result case final SaveResult result
            when result is! SaveDone) ...[
          const SizedBox(height: AppSizes.spaceM),
          FormMessage(saveProblemText(result)),
        ],
      ],
    );
  }
}

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
            StatusLine(
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
