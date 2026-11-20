// The two gates in front of every screen that signs a custody step
// (registration plan §4; shared since Transporter handoff T3): the
// encrypted database must open, and this phone must be allowed to sign.
// Neither problem can be fixed on such a screen, so each gets its own plain
// message and a way home instead of a dead form.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../device_key/presentation/device_key_controller.dart';
import '../data/local_steps_repository.dart';

/// Shows [child] once the database is open and the device key may sign;
/// otherwise a wait or the reason, with "Back to home" to [homePath].
class SavedWorkGate extends ConsumerWidget {
  const SavedWorkGate({required this.homePath, required this.child, super.key});

  final String homePath;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final steps = ref.watch(localStepsRepositoryProvider);
    final key = ref.watch(deviceKeyControllerProvider);

    if (steps.isLoading) return const _Waiting(AppText.openingSavedWork);
    if (steps.hasError) {
      return _Blocked(
        icon: Icons.storage,
        text: AppText.savedWorkProblem,
        homePath: homePath,
      );
    }
    return switch (key) {
      DeviceKeyReady() || DeviceKeyUnregistered() => child,
      DeviceKeyOtherDevice() => _Blocked(
        icon: Icons.phonelink_lock,
        text: AppText.deviceKeyOtherDevice,
        homePath: homePath,
      ),
      DeviceKeyFailed(:final message) => _Blocked(
        icon: Icons.phonelink_lock,
        text: message,
        homePath: homePath,
      ),
      DeviceKeyChecking() ||
      DeviceKeyNotNeeded() => const _Waiting(AppText.checkingDeviceKey),
    };
  }
}

/// Back to the screen below, or to [homePath] when there is none (the
/// screen was opened by its address).
void backOrHome(BuildContext context, String homePath) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(homePath);
  }
}

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
  const _Blocked({
    required this.icon,
    required this.text,
    required this.homePath,
  });
  final IconData icon;
  final String text;
  final String homePath;

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
            onPressed: () => backOrHome(context, homePath),
            child: const Text(AppText.backToHome),
          ),
        ],
      ),
    ),
  );
}
