// What a screen that signs a custody step shows after Save (registration
// plan M5; shared since Transporter handoff T4): the committed "Saved on
// this phone", the way on to the next bag, and home. Also the sentence for
// each refused save, so both screens say them the same way.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../data/save_signed_step.dart';

/// The sentence under Save for a save that did not happen.
String saveProblemText(SaveResult result) => switch (result) {
  SaveDone() => AppText.savedOnPhone,
  SaveKeyNotUsable() => AppText.saveKeyNotUsable,
  SaveInvalidField() => AppText.saveInvalid,
  SaveSigningFailed() => AppText.saveSigningFailed,
  SaveNoScreenLock() => AppText.saveNoScreenLock,
  SaveDuplicateStepId() => AppText.saveFailed,
  SaveStorageFailed() => AppText.savedWorkProblem,
  SaveBusy() => AppText.saveBusy, // calm: Save again works (Mobile (26))
};

class SavedView extends StatelessWidget {
  const SavedView({
    required this.duration,
    required this.anotherLabel,
    required this.onAnother,
    required this.onHome,
    super.key,
  });

  final Duration? duration;
  final String anotherLabel;
  final VoidCallback onAnother;
  final VoidCallback onHome;

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
              FilledButton(onPressed: onAnother, child: Text(anotherLabel)),
              const SizedBox(height: AppSizes.spaceS),
              OutlinedButton(
                onPressed: onHome,
                child: const Text(AppText.backToHome),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
