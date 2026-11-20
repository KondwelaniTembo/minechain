// "Register consignment" (plan M5, FR-01): scan the custody record, wait for
// a real GPS fix, choose the mineral, type the weight, Save. Works offline:
// the step is signed and kept on the phone until it can be sent.
//
// Three taps for a returning miner (plan Q5): the home tile, the mineral
// (skipped when the remembered one is right), Save. Scanning finishes by
// itself and the fix arrives by itself; typing the weight is data entry.
//
// Before the form, two gates: the encrypted database must open, and this
// phone must be allowed to sign (plan §4), in SavedWorkGate, shared with
// "Take custody".

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/form_message.dart';
import '../../../core/widgets/status_line.dart';
import '../../steps/presentation/location_status_view.dart';
import '../../steps/presentation/saved_view.dart';
import '../../steps/presentation/saved_work_gate.dart';
import '../../steps/presentation/weight_field.dart';
import '../data/location_source.dart';
import '../data/register_consignment.dart';
import 'mineral_chips.dart';
import 'qr_scanner_view.dart';
import 'registration_controller.dart';

class RegisterConsignmentScreen extends StatelessWidget {
  const RegisterConsignmentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => _back(context)),
        title: const Text(AppText.registerConsignment),
      ),
      body: const SafeArea(
        child: SavedWorkGate(homePath: AppRoutes.miner, child: _Form()),
      ),
    );
  }
}

void _back(BuildContext context) => backOrHome(context, AppRoutes.miner);

// ---- The form ----------------------------------------------------------------

class _Form extends ConsumerStatefulWidget {
  const _Form();

  @override
  ConsumerState<_Form> createState() => _FormState();
}

class _FormState extends ConsumerState<_Form> with WidgetsBindingObserver {
  final _weight = TextEditingController();
  final _weightFocus = FocusNode();

  /// Whether the weight's format problems are shown. Not while typing:
  /// "12." is on its way to "12.5", not a mistake (found on the A57). They
  /// appear when the field loses focus or when the greyed-out Save is
  /// tapped, and go again as soon as the weight is edited.
  bool _showWeightProblems = false;

  @override
  void initState() {
    super.initState();
    // To try the location again when the user comes back from the phone's
    // settings page (location switched on, or permission allowed there).
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

  void _weightEdited(String text) {
    ref.read(registrationControllerProvider.notifier).weightChanged(text);
    if (_showWeightProblems) setState(() => _showWeightProblems = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final controller = ref.read(registrationControllerProvider.notifier);
    // ask: false. Closing any permission dialog also "resumes" the app; an
    // automatic request here could open a second dialog on top of the
    // camera's, or ask again straight after a refusal. Only the buttons ask.
    if (controller.locationBlocked) controller.startLocation(ask: false);
  }

  @override
  Widget build(BuildContext context) {
    final form = ref.watch(registrationControllerProvider);
    final controller = ref.read(registrationControllerProvider.notifier);

    if (form.result is SaveDone) {
      return SavedView(
        duration: form.saveDuration,
        anotherLabel: AppText.registerAnother,
        onAnother: () {
          _weight.clear();
          _showWeightProblems = false;
          controller.registerAnother();
        },
        onHome: () => _back(context),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSizes.spaceM),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Section(
                title: AppText.scanStep,
                child: _ScanPart(form: form, controller: controller),
              ),
              _Section(
                title: AppText.locationStep,
                child: _LocationPart(form: form, controller: controller),
              ),
              _Section(
                title: AppText.mineralStep,
                child: _MineralPart(form: form, controller: controller),
              ),
              _Section(
                title: AppText.weightStep,
                child: _WeightPart(
                  form: form,
                  text: _weight,
                  focus: _weightFocus,
                  showProblems: _showWeightProblems,
                  onChanged: _weightEdited,
                ),
              ),
              // A disabled button ignores taps, so this catches a tap on the
              // greyed-out Save and shows why it cannot save yet.
              GestureDetector(
                onTap: form.canSave ? null : _revealWeightProblems,
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
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSizes.spaceL),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSizes.spaceS),
        child,
      ],
    ),
  );
}

// ---- 1. Scan -----------------------------------------------------------------

class _ScanPart extends ConsumerWidget {
  const _ScanPart({required this.form, required this.controller});
  final RegistrationState form;
  final RegistrationController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final code = form.qrCode;
    if (code != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatusLine(icon: Icons.qr_code_2, text: AppText.scannedRecord(code)),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: form.saving ? null : controller.scanAgain,
              child: const Text(AppText.scanAnother),
            ),
          ),
        ],
      );
    }

    final scanner = ref.watch(qrScannerBuilderProvider);
    final notice = form.qrNotice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppSizes.tileRadius),
          child: SizedBox(
            height: 220,
            // The scanner asks for the camera as soon as it is built, so it
            // is not built while the location question may be on screen.
            child: form.cameraMayStart
                ? scanner(
                    onCode: controller.onScanned,
                    problemBuilder: (context, problem, retry) =>
                        _ScannerProblem(problem: problem, retry: retry),
                  )
                : ColoredBox(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    child: const Center(
                      child: Padding(
                        padding: EdgeInsets.all(AppSizes.spaceM),
                        child: Text(
                          AppText.cameraWaiting,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: AppSizes.spaceS),
        const Text(AppText.scanHint),
        if (notice != null) ...[
          const SizedBox(height: AppSizes.spaceS),
          StatusLine(
            icon: Icons.error_outline,
            error: true,
            text: switch (notice) {
              QrNotOurs() => AppText.notOurRecord,
              QrAlreadyRegistered(:final on) => AppText.alreadyRegistered(
                on.toLocal(),
              ),
            },
          ),
        ],
      ],
    );
  }
}

class _ScannerProblem extends ConsumerWidget {
  const _ScannerProblem({required this.problem, required this.retry});
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
            if (problem == ScannerProblem.permissionDenied) ...[
              const SizedBox(height: AppSizes.spaceS),
              Wrap(
                spacing: AppSizes.spaceS,
                runSpacing: AppSizes.spaceS,
                children: [
                  FilledButton(
                    onPressed: retry,
                    child: const Text(AppText.allowCamera),
                  ),
                  // Android stops showing the dialog after repeated refusals;
                  // then only the app's settings page can allow it.
                  OutlinedButton(
                    onPressed: () =>
                        ref.read(locationSourceProvider).openAppSettings(),
                    child: const Text(AppText.openSettings),
                  ),
                ],
              ),
            ] else if (problem == ScannerProblem.failed) ...[
              const SizedBox(height: AppSizes.spaceS),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton(
                  onPressed: retry,
                  child: const Text(AppText.tryAgain),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---- 2. Location -------------------------------------------------------------

class _LocationPart extends StatelessWidget {
  const _LocationPart({required this.form, required this.controller});
  final RegistrationState form;
  final RegistrationController controller;

  @override
  Widget build(BuildContext context) => LocationStatusView(
    status: form.location,
    onStart: controller.startLocation,
    onOpenLocationSettings: controller.openLocationSettings,
    onOpenAppSettings: controller.openAppSettings,
  );
}

// ---- 3. Mineral --------------------------------------------------------------

class _MineralPart extends StatelessWidget {
  const _MineralPart({required this.form, required this.controller});
  final RegistrationState form;
  final RegistrationController controller;

  @override
  Widget build(BuildContext context) => MineralChips(
    selected: form.mineral,
    enabled: !form.saving,
    onSelected: controller.chooseMineral,
  );
}

// ---- 4. Weight ---------------------------------------------------------------

class _WeightPart extends StatelessWidget {
  const _WeightPart({
    required this.form,
    required this.text,
    required this.focus,
    required this.showProblems,
    required this.onChanged,
  });
  final RegistrationState form;
  final TextEditingController text;
  final FocusNode focus;
  final bool showProblems;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => WeightField(
    unit: form.mineral?.unit,
    controller: text,
    focus: focus,
    enabled: !form.saving,
    showProblems: showProblems,
    onChanged: onChanged,
  );
}
