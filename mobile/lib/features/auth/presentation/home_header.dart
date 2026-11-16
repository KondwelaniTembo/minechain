// What every role's home shows above its tiles: the server status (F5) and,
// while the token has expired, a notice that the password will be asked for.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/server_status_banner.dart';
import '../domain/auth_state.dart';
import 'auth_controller.dart';

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
/// SignedInNeedsPassword (decision Q2), otherwise nothing. No button yet: the
/// password prompt comes with the first server action, in a later module.
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
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppSizes.tileRadius),
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.key, color: scheme.onSecondaryContainer),
              const SizedBox(width: AppSizes.spaceM),
              Expanded(
                child: Text(
                  AppText.needsPasswordNotice,
                  style: TextStyle(color: scheme.onSecondaryContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
