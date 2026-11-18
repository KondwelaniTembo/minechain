// What every role's home shows above its tiles: the server status (F5) and,
// while the token has expired, a notice that the password will be asked for.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/server_status_banner.dart';
import '../domain/auth_state.dart';
import 'auth_controller.dart';
import 'password_prompt.dart';

/// The shared header of the five homes.
class HomeHeader extends StatelessWidget {
  const HomeHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [ServerStatusBanner(), NeedsPasswordNotice()],
    );
  }
}

/// "Enter your password the next time you send your work." while the state is
/// SignedInNeedsPassword (decision Q2), otherwise nothing. Its small "Enter
/// password" button opens the password prompt now, for a user who would
/// rather do it while they have a signal than wait for the next send.
class NeedsPasswordNotice extends ConsumerWidget {
  const NeedsPasswordNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! SignedInNeedsPassword) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSizes.spaceM),
      child: Material(
        // Patina green like the server notices, not the sand of the tiles:
        // this is something to read, not a tile to tap.
        color: scheme.tertiaryContainer,
        elevation: 2,
        shadowColor: AppTheme.shadow,
        borderRadius: BorderRadius.circular(AppSizes.tileRadius),
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.key, color: scheme.onTertiaryContainer),
              const SizedBox(width: AppSizes.spaceM),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppText.needsPasswordNotice,
                      style: TextStyle(color: scheme.onTertiaryContainer),
                    ),
                    const SizedBox(height: AppSizes.spaceXs),
                    // A text button: lighter than the home's tiles, so it
                    // does not compete with the role's main action, but still
                    // a full-height tap target.
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, AppSizes.tapTargetMin),
                      ),
                      // The Future's answer is not needed here: on success
                      // the state changes and this notice disappears.
                      onPressed: () => showPasswordPrompt(context),
                      child: const Text(AppText.enterPasswordButton),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
