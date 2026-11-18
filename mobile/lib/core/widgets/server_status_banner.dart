// A strip at the top of a screen saying what is happening with the server:
// waking up, not ready, or why it could not be reached (plan section 5.5).
// It shows nothing when all is well, so it only takes space when it matters.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../errors/app_failure.dart';
import '../errors/failure_text.dart';
import '../network/server_status.dart';
import '../text/app_text.dart';
import '../theme/app_theme.dart';
import '../theme/sizes.dart';

/// Shows the current [ServerStatus] in plain words, with an icon.
///
/// A ConsumerWidget is a StatelessWidget that can watch providers: `ref.watch`
/// rebuilds this widget whenever the status changes.
class ServerStatusBanner extends ConsumerWidget {
  const ServerStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(serverStatusControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    void tryAgain() => ref.read(serverStatusControllerProvider.notifier).check();

    return switch (status) {
      // Nothing to say. "Checking" stays silent too: most answers come within
      // the first 3 s, and a banner that flashes up and away is just noise.
      ServerUnknown() || ServerChecking() || ServerReady() =>
        const SizedBox.shrink(),
      ServerWaking() => _Banner(
        icon: Icons.hourglass_top,
        text: AppText.serverWaking,
        // Patina green, not the sand of the home tiles: a notice must not
        // look like something to tap.
        background: scheme.tertiaryContainer,
        foreground: scheme.onTertiaryContainer,
        // A moving indicator shows the app is not frozen during the wait.
        showProgress: true,
      ),
      ServerNotReady() => _Banner(
        icon: Icons.cloud_off,
        text: AppText.serverNotReady,
        background: scheme.tertiaryContainer,
        foreground: scheme.onTertiaryContainer,
        onTryAgain: tryAgain,
      ),
      ServerFailed(:final failure) => _Banner(
        icon: failure is InsecureConnection ? Icons.gpp_bad : Icons.error_outline,
        text: failureText(failure),
        background: scheme.errorContainer,
        foreground: scheme.onErrorContainer,
        // No "Try again" for an unsafe connection: retrying on the same
        // network would meet the same interception, and the button would
        // invite the user to keep pushing past a warning.
        onTryAgain: failure is InsecureConnection ? null : tryAgain,
      ),
    };
  }
}

/// The banner's look, shared by every state.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.background,
    required this.foreground,
    this.showProgress = false,
    this.onTryAgain,
  });

  final IconData icon;
  final String text;
  final Color background;
  final Color foreground;
  final bool showProgress;
  final VoidCallback? onTryAgain;

  @override
  Widget build(BuildContext context) {
    // liveRegion asks TalkBack to read the banner out when it appears or
    // changes, since a blind user would not notice it otherwise. The bottom
    // padding is the gap to whatever comes below; the banner brings it only
    // when it is shown.
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSizes.spaceM),
      child: Semantics(
      liveRegion: true,
      child: Material(
        color: background,
        // A light shadow, lower than the home's tiles: a banner sits above the
        // page, but must not compete with the actions.
        elevation: 2,
        shadowColor: AppTheme.shadow,
        borderRadius: BorderRadius.circular(AppSizes.tileRadius),
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The icon and the words carry the meaning; the colour only
                  // helps (plan section 7).
                  // A status strip's icon is smaller than a tile's: at the
                  // tile size it outweighed the sentence beside it.
                  Icon(icon, color: foreground, size: AppSizes.statusIcon),
                  const SizedBox(width: AppSizes.spaceM),
                  // Expanded gives the text the rest of the row's width, so
                  // a long sentence or large text wraps instead of
                  // overflowing.
                  Expanded(
                    child: Text(
                      text,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyLarge?.copyWith(color: foreground),
                    ),
                  ),
                ],
              ),
              if (showProgress) ...[
                const SizedBox(height: AppSizes.spaceM),
                LinearProgressIndicator(color: foreground),
              ],
              if (onTryAgain != null) ...[
                const SizedBox(height: AppSizes.spaceS),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    onPressed: onTryAgain,
                    icon: Icon(Icons.refresh, color: foreground),
                    label: Text(
                      AppText.tryAgain,
                      style: TextStyle(color: foreground),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }
}
