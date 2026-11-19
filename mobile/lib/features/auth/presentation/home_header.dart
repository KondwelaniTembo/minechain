// What every role's home shows above its tiles: the server status (F5) and,
// while the token has expired, a notice that the password will be asked for.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../core/widgets/server_status_banner.dart';
import '../domain/auth_state.dart';
import 'auth_controller.dart';
import 'password_prompt.dart';

/// The signed-in user's username, for the role pill in a home's top bar
/// (decision Mobile (36)); null when nobody is signed in. Watching it rebuilds
/// the home if the user changes.
String? watchUsername(WidgetRef ref) => switch (ref.watch(
  authControllerProvider,
)) {
  SignedIn(:final user) || SignedInNeedsPassword(:final user) => user.username,
  _ => null,
};

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
        // The main tile's copper (decision Mobile (36)): the green of the
        // first restyle clashed with the copper theme on the phone. The key
        // icon and the sentence say what this is, so it does not rely on
        // colour to be told apart from the main tile.
        color: scheme.primary,
        elevation: 2,
        shadowColor: AppTheme.shadow,
        borderRadius: BorderRadius.circular(AppSizes.tileRadius),
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.key, color: scheme.onPrimary),
              const SizedBox(width: AppSizes.spaceM),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppText.needsPasswordNotice,
                      style: TextStyle(color: scheme.onPrimary),
                    ),
                    const SizedBox(height: AppSizes.spaceS),
                    // The Future's answer is not needed here: on success the
                    // state changes and this notice disappears.
                    PillButton(
                      label: AppText.enterPasswordButton,
                      onPressed: () => showPasswordPrompt(context),
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
