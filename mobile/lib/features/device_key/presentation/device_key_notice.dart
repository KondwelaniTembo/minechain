// The home's warning when this phone may not sign (plan M2 and §4): "This
// phone is not your registered phone. Ask an administrator to reset your
// device key." Shown for otherDevice and failed; nothing otherwise.
//
// Shown on the miner's home now. The transporter's and buyer's homes get it
// with their own modules, when they start signing steps.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import 'device_key_controller.dart';

class DeviceKeyNotice extends ConsumerWidget {
  const DeviceKeyNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = switch (ref.watch(deviceKeyControllerProvider)) {
      DeviceKeyOtherDevice() => AppText.deviceKeyOtherDevice,
      DeviceKeyFailed(:final message) => message,
      _ => null,
    };
    if (message == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSizes.spaceM),
      // liveRegion: TalkBack reads it out when it appears.
      child: Semantics(
        liveRegion: true,
        child: Material(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(AppSizes.tileRadius),
          child: Padding(
            padding: const EdgeInsets.all(AppSizes.spaceM),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // An icon as well as the colour (plan section 7).
                Icon(Icons.phonelink_lock, color: scheme.onErrorContainer),
                const SizedBox(width: AppSizes.spaceM),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
