// "Register consignment" (plan M5, FR-01): scan the custody record, wait for
// a real GPS fix, choose the mineral, type the weight, Save. Works offline:
// the step is signed and kept on the phone until it can be sent.
//
// Three taps for a returning miner (plan Q5): the home tile, the mineral
// (skipped when the remembered one is right), Save. Scanning finishes by
// itself and the fix arrives by itself; typing the weight is data entry.
//
// Before the form, two gates: the encrypted database must open, and this
// phone must be allowed to sign (plan §4). Neither problem can be fixed on
// this screen, so each gets its own plain message instead of a dead form.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/form_message.dart';
import '../../device_key/presentation/device_key_controller.dart';
import '../../steps/data/local_steps_repository.dart';
import '../data/location_source.dart';
import '../data/register_consignment.dart';
import '../domain/mineral.dart';
import '../domain/weight.dart';
import 'qr_scanner_view.dart';
import 'registration_controller.dart';

class RegisterConsignmentScreen extends ConsumerWidget {
  const RegisterConsignmentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final steps = ref.watch(localStepsRepositoryProvider);
    final key = ref.watch(deviceKeyControllerProvider);

    final Widget body;
    if (steps.isLoading) {
      body = const _Waiting(AppText.openingSavedWork);
    } else if (steps.hasError) {
      body = const _Blocked(
        icon: Icons.storage,
        text: AppText.savedWorkProblem,
      );
    } else {
      body = switch (key) {
        DeviceKeyReady() || DeviceKeyUnregistered() => const _Form(),
        DeviceKeyOtherDevice() => const _Blocked(
          icon: Icons.phonelink_lock,
          text: AppText.deviceKeyOtherDevice,
        ),
        DeviceKeyFailed(:final message) => _Blocked(
          icon: Icons.phonelink_lock,
          text: message,
        ),
        DeviceKeyChecking() ||
        DeviceKeyNotNeeded() => const _Waiting(AppText.checkingDeviceKey),
      };
    }

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => _back(context)),
        title: const Text(AppText.registerConsignment),
      ),
      body: SafeArea(child: body),
    );
  }
}

void _back(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(AppRoutes.miner);
  }
}

// ---- Gates ------------------------------------------------------------------

class _Waiting extends StatelessWidget {
  const _Waiting(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(AppSizes.spaceL),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: AppSizes.spaceM),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _Blocked extends StatelessWidget {
  const _Blocked({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(AppSizes.spaceL),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Icon(
              icon,
              size: AppSizes.tileIcon,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          const SizedBox(height: AppSizes.spaceM),
          Semantics(
            liveRegion: true,
            child: Text(text, textAlign: TextAlign.center),
          ),
          const SizedBox(height: AppSizes.spaceL),
          FilledButton(
            onPressed: () => _back(context),
            child: const Text(AppText.backToHome),
          ),
        ],
      ),
    ),
  );
}

// ---- The form ----------------------------------------------------------------

class _Form extends ConsumerStatefulWidget {
  const _Form();

  @override
  ConsumerState<_Form> createState() => _FormState();
}

class _FormState extends ConsumerState<_Form> with WidgetsBindingObserver {
  final _weight = TextEditingController();

  @override
  void initState() {
    super.initState();
    // To try the location again when the user comes back from the phone's
    // settings page (location switched on, or permission allowed there).
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _weight.dispose();
    super.dispose();
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
      return _Saved(
        duration: form.saveDuration,
        onAnother: () {
          _weight.clear();
          controller.registerAnother();
        },
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
                  controller: controller,
                  text: _weight,
                ),
              ),
              FilledButton.icon(
                onPressed: form.canSave ? controller.save : null,
                icon: form.saving
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(form.saving ? AppText.saving : AppText.save),
              ),
              if (form.result case final SaveResult result
                  when result is! SaveDone) ...[
                const SizedBox(height: AppSizes.spaceM),
                FormMessage(_saveProblemText(result)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _saveProblemText(SaveResult result) => switch (result) {
  SaveDone() => AppText.savedOnPhone,
  SaveKeyNotUsable() => AppText.saveKeyNotUsable,
  SaveInvalidField() => AppText.saveInvalid,
  SaveSigningFailed() => AppText.saveSigningFailed,
  SaveDuplicateStepId() => AppText.saveFailed,
  SaveStorageFailed() => AppText.savedWorkProblem,
};

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

/// An icon and a sentence, never colour alone (plan section 7).
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
    final color = error ? Theme.of(context).colorScheme.error : null;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Icon(icon, color: color)),
          const SizedBox(width: AppSizes.spaceS),
          Expanded(
            child: Text(text, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
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
          _StatusLine(icon: Icons.qr_code_2, text: AppText.scannedRecord(code)),
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
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
          _StatusLine(
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
            _StatusLine(
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
  Widget build(BuildContext context) {
    final (
      IconData icon,
      String text,
      bool error,
      Widget? action,
    ) = switch (form.location) {
      LocationStarting() => (
        Icons.gps_not_fixed,
        AppText.startingLocation,
        false,
        null,
      ),
      LocationSearching(:final accuracyM, :final stillLooking) => (
        Icons.gps_not_fixed,
        stillLooking
            ? '${AppText.findingLocation(accuracyM)}\n${AppText.stillLooking}'
            : AppText.findingLocation(accuracyM),
        false,
        null,
      ),
      LocationFound(:final fix) => (
        Icons.gps_fixed,
        AppText.locationFound(fix.accuracyM),
        false,
        null,
      ),
      LocationMocked() => (Icons.gps_off, AppText.fakeLocation, true, null),
      LocationFailed() => (
        Icons.gps_off,
        AppText.locationFailed,
        true,
        FilledButton(
          onPressed: controller.startLocation,
          child: const Text(AppText.tryAgain),
        ),
      ),
      LocationBlocked(:final access) => switch (access) {
        LocationAccess.serviceOff => (
          Icons.location_disabled,
          AppText.locationOff,
          true,
          FilledButton(
            onPressed: controller.openLocationSettings,
            child: const Text(AppText.turnOnLocation),
          ),
        ),
        LocationAccess.deniedOnce => (
          Icons.location_disabled,
          AppText.locationNeeded,
          true,
          FilledButton(
            onPressed: controller.startLocation,
            child: const Text(AppText.allowLocation),
          ),
        ),
        LocationAccess.deniedForever => (
          Icons.location_disabled,
          AppText.locationRefused,
          true,
          FilledButton(
            onPressed: controller.openAppSettings,
            child: const Text(AppText.openSettings),
          ),
        ),
        LocationAccess.approximateOnly => (
          Icons.location_searching,
          AppText.locationApproximate,
          true,
          FilledButton(
            onPressed: controller.openAppSettings,
            child: const Text(AppText.openSettings),
          ),
        ),
        // Never stored as "blocked"; listed so the switch is complete.
        LocationAccess.granted => (
          Icons.gps_not_fixed,
          AppText.startingLocation,
          false,
          null,
        ),
      },
    };

    final searching =
        form.location is LocationStarting || form.location is LocationSearching;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusLine(icon: icon, text: text, error: error),
        if (searching) ...[
          const SizedBox(height: AppSizes.spaceS),
          const LinearProgressIndicator(),
        ],
        if (action != null) ...[
          const SizedBox(height: AppSizes.spaceS),
          Align(alignment: AlignmentDirectional.centerStart, child: action),
        ],
      ],
    );
  }
}

// ---- 3. Mineral --------------------------------------------------------------

String _mineralName(Mineral mineral) => switch (mineral) {
  Mineral.gold => AppText.gold,
  Mineral.copper => AppText.copper,
  Mineral.cobalt => AppText.cobalt,
  Mineral.manganese => AppText.manganese,
  Mineral.emerald => AppText.emerald,
  Mineral.amethyst => AppText.amethyst,
};

class _MineralPart extends StatelessWidget {
  const _MineralPart({required this.form, required this.controller});
  final RegistrationState form;
  final RegistrationController controller;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: AppSizes.spaceS,
    runSpacing: AppSizes.spaceS,
    children: [
      for (final mineral in Mineral.values)
        ChoiceChip(
          label: Text(_mineralName(mineral)),
          selected: form.mineral == mineral,
          onSelected: form.saving
              ? null
              : (_) => controller.chooseMineral(mineral),
        ),
    ],
  );
}

// ---- 4. Weight ---------------------------------------------------------------

String? _weightError(RegistrationState form) {
  if (form.weightText.trim().isEmpty) return null; // nothing typed yet
  final mineral = form.mineral;
  if (mineral == null) return AppText.chooseMineralFirst;
  return switch (form.weight) {
    WeightRefused(problem: WeightProblem.empty) || WeightOk() || null => null,
    WeightRefused(problem: WeightProblem.negative) => AppText.weightNegative,
    WeightRefused(problem: WeightProblem.notANumber) =>
      AppText.weightNotANumber,
    WeightRefused(problem: WeightProblem.tooManyDecimals) =>
      AppText.weightTooManyDecimals(mineral.unit.decimals),
    WeightRefused(problem: WeightProblem.zero) => AppText.weightZero,
    WeightRefused(problem: WeightProblem.tooLarge) => AppText.weightTooLarge,
  };
}

class _WeightPart extends StatelessWidget {
  const _WeightPart({
    required this.form,
    required this.controller,
    required this.text,
  });
  final RegistrationState form;
  final RegistrationController controller;
  final TextEditingController text;

  @override
  Widget build(BuildContext context) {
    final unit = form.mineral?.unit;
    return TextField(
      controller: text,
      enabled: !form.saving,
      // The number keyboard with a decimal key.
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      // No suggestions or learning: weights are not words, and the keyboard
      // must not remember them.
      autocorrect: false,
      enableSuggestions: false,
      onChanged: controller.weightChanged,
      decoration: InputDecoration(
        labelText: unit == WeightUnit.kilograms
            ? AppText.weightInKilograms
            : AppText.weightInGrams,
        suffixText: unit == WeightUnit.kilograms
            ? AppText.kilograms
            : AppText.grams,
        errorText: _weightError(form),
        errorMaxLines: 3,
      ),
    );
  }
}

// ---- Saved -------------------------------------------------------------------

class _Saved extends StatelessWidget {
  const _Saved({required this.duration, required this.onAnother});
  final Duration? duration;
  final VoidCallback onAnother;

  @override
  Widget build(BuildContext context) {
    // The save's duration, in debug builds only, for measuring NFR-03 on
    // the A57. It is a number of seconds and nothing else; release builds
    // never show it, and it is never logged.
    final timing = kDebugMode && duration != null
        ? ' (${(duration!.inMilliseconds / 1000).toStringAsFixed(1)} s)'
        : '';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSizes.spaceL),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeSemantics(
                child: Icon(
                  Icons.check_circle,
                  size: AppSizes.primaryTileIcon,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: AppSizes.spaceM),
              Semantics(
                liveRegion: true,
                child: Text(
                  '${AppText.savedOnPhone}$timing',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: AppSizes.spaceL),
              FilledButton(
                onPressed: onAnother,
                child: const Text(AppText.registerAnother),
              ),
              const SizedBox(height: AppSizes.spaceS),
              OutlinedButton(
                onPressed: () => _back(context),
                child: const Text(AppText.backToHome),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
