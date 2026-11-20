// What the GPS is doing, in words, with the one button that can help
// (registration plan M5, §5; shared since Transporter handoff T4): "Finding
// your location… 40 m", "Location is off" with "Turn on location", and so on.

import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/status_line.dart';
import '../../registration/data/location_source.dart';
import 'location_tracker.dart';

class LocationStatusView extends StatelessWidget {
  const LocationStatusView({
    required this.status,
    required this.onStart,
    required this.onOpenLocationSettings,
    required this.onOpenAppSettings,
    super.key,
  });

  final LocationStatus status;

  /// "Try again" and "Allow location".
  final VoidCallback onStart;
  final VoidCallback onOpenLocationSettings;
  final VoidCallback onOpenAppSettings;

  @override
  Widget build(BuildContext context) {
    final (
      IconData icon,
      String text,
      bool error,
      Widget? action,
    ) = switch (status) {
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
        FilledButton(onPressed: onStart, child: const Text(AppText.tryAgain)),
      ),
      LocationBlocked(:final access) => switch (access) {
        LocationAccess.serviceOff => (
          Icons.location_disabled,
          AppText.locationOff,
          true,
          FilledButton(
            onPressed: onOpenLocationSettings,
            child: const Text(AppText.turnOnLocation),
          ),
        ),
        LocationAccess.deniedOnce => (
          Icons.location_disabled,
          AppText.locationNeeded,
          true,
          FilledButton(
            onPressed: onStart,
            child: const Text(AppText.allowLocation),
          ),
        ),
        LocationAccess.deniedForever => (
          Icons.location_disabled,
          AppText.locationRefused,
          true,
          FilledButton(
            onPressed: onOpenAppSettings,
            child: const Text(AppText.openSettings),
          ),
        ),
        LocationAccess.approximateOnly => (
          Icons.location_searching,
          AppText.locationApproximate,
          true,
          FilledButton(
            onPressed: onOpenAppSettings,
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

    final searching = status is LocationStarting || status is LocationSearching;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusLine(icon: icon, text: text, error: error),
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
