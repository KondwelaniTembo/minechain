// The signed-in user's own account (plan section 4.1, /account): who is
// signed in on this phone, and Log out. Changing the password comes later.
//
// Like the login screen, this screen decides nothing. It shows the user from
// AuthController's state and calls logOut(); the router moves to /login by
// itself when the state becomes SignedOut.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/pill_button.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/domain/user.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/password_prompt.dart';
import '../../device_key/domain/key_fingerprint.dart';
import '../../device_key/presentation/device_key_controller.dart';

/// The plain word for a role, the same as its home's title.
String roleLabel(Role role) => switch (role) {
  Role.miner => AppText.minerTitle,
  Role.transporter => AppText.transporterTitle,
  Role.buyer => AppText.buyerTitle,
  Role.officer => AppText.officerTitle,
  Role.admin => AppText.adminTitle,
};

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    // Both "signed in" states have a user. Any other state only shows for a
    // moment, while the router is already moving to /login or /start.
    final User? user = switch (auth) {
      SignedIn(:final user) || SignedInNeedsPassword(:final user) => user,
      SignedOut() || AuthUnknown() => null,
    };

    return Scaffold(
      appBar: AppBar(
        // No back arrow (Mobile (37), Q10): "My account" is one of the
        // navigation bar's two places, like Home, not a page on top of the
        // home. Home is one tap away in the bar, and Android's back button
        // goes there too (app_navigation.dart).
        automaticallyImplyLeading: false,
        title: const Text(AppText.myAccount),
      ),
      body: SafeArea(
        child: user == null
            ? const SizedBox.shrink()
            : SingleChildScrollView(
                padding: const EdgeInsets.all(AppSizes.spaceM),
                child: Center(
                  child: ConstrainedBox(
                    // On a turned phone the content stays a readable width
                    // instead of stretching across the whole screen.
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (auth is SignedInNeedsPassword) ...[
                          const _NeedsPasswordCard(),
                          const SizedBox(height: AppSizes.spaceM),
                        ],
                        _AccountDetails(user),
                        const SizedBox(height: AppSizes.spaceL),
                        // Tonal, not the strong copper button: logging out is
                        // something to find, not the screen's main action, and
                        // the dialog asks again before anything happens.
                        FilledButton.tonalIcon(
                          onPressed: () => _confirmLogOut(context, ref),
                          icon: const Icon(Icons.logout),
                          label: const Text(AppText.logOut),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  /// Asks first, because logging out on a mine site with no signal locks the
  /// user out until they have a network again (logging in needs the server).
  Future<void> _confirmLogOut(BuildContext context, WidgetRef ref) async {
    // Read the controller before waiting: after the await this screen may be
    // gone, and a widget that is gone must not use its ref.
    final controller = ref.read(authControllerProvider.notifier);

    // The dialog answers true (Log out), false (Cancel) or null (dismissed
    // with the back button or a tap outside). Only true logs out.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const _LogOutDialog(),
    );
    if (confirmed != true) return;

    // No navigation here: the state becomes SignedOut, and the router's
    // redirect moves to /login on its own.
    await controller.logOut();
  }
}

/// "Log out of MineChain?" with Cancel and Log out.
class _LogOutDialog extends StatelessWidget {
  const _LogOutDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text(AppText.logOutQuestion),
      content: const Text(AppText.logOutExplanation),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text(AppText.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text(AppText.logOut),
        ),
      ],
    );
  }
}

/// The expired-session notice with its "Enter your password" button.
class _NeedsPasswordCard extends StatelessWidget {
  const _NeedsPasswordCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The same copper notice as on the homes (decision Mobile (36)), so the
    // same state looks the same everywhere.
    return Material(
      color: scheme.primary,
      elevation: 2,
      shadowColor: AppTheme.shadow,
      borderRadius: BorderRadius.circular(AppSizes.tileRadius),
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.spaceM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.key, color: scheme.onPrimary),
                const SizedBox(width: AppSizes.spaceM),
                Expanded(
                  child: Text(
                    AppText.accountNeedsPassword,
                    style: TextStyle(color: scheme.onPrimary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSizes.spaceM),
            // The answer is not needed: on success the state becomes SignedIn
            // and this card disappears on its own.
            PillButton(
              label: AppText.enterYourPassword,
              onPressed: () => showPasswordPrompt(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// Name, role, username and (if there is one) licence number.
class _AccountDetails extends StatelessWidget {
  const _AccountDetails(this.user);

  final User user;

  @override
  Widget build(BuildContext context) {
    final licence = user.licenceNumber;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSizes.spaceS),
        child: Column(
          children: [
            _DetailRow(
              icon: Icons.person,
              label: AppText.fullName,
              value: user.fullName,
            ),
            _DetailRow(
              icon: Icons.work,
              label: AppText.role,
              value: roleLabel(user.role),
            ),
            _DetailRow(
              icon: Icons.badge,
              label: AppText.username,
              value: user.username,
            ),
            // Officers and administrators have no licence: the row is left
            // out rather than showing an empty value.
            if (licence != null)
              _DetailRow(
                icon: Icons.verified,
                label: AppText.licenceNumber,
                value: licence,
              ),
            // Only the roles that sign steps have a device key (plan M2).
            if (signingRoles.contains(user.role)) const _DeviceKeyRow(),
          ],
        ),
      ),
    );
  }
}

/// "Device key": registered (with the start of its fingerprint), not yet
/// registered, or not this phone (plan M2).
class _DeviceKeyRow extends ConsumerWidget {
  const _DeviceKeyRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = switch (ref.watch(deviceKeyControllerProvider)) {
      DeviceKeyReady(:final fingerprint) => AppText.deviceKeyRegistered(
        shortFingerprint(fingerprint),
      ),
      DeviceKeyUnregistered() => AppText.deviceKeyNotRegistered,
      DeviceKeyOtherDevice() => AppText.deviceKeyOtherDevice,
      DeviceKeyFailed(:final message) => message,
      // notNeeded only shows for a signing role before the first check has
      // started, for a moment after start-up.
      DeviceKeyChecking() || DeviceKeyNotNeeded() => AppText.deviceKeyChecking,
    };
    return _DetailRow(icon: Icons.key, label: AppText.deviceKey, value: value);
  }
}

/// One detail: an icon, a small label, and the value under it.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // MergeSemantics: TalkBack reads "Full name, Mutale Banda" as one item
    // instead of two separate ones.
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSizes.spaceM,
          vertical: AppSizes.spaceS,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(child: Icon(icon)),
            const SizedBox(width: AppSizes.spaceM),
            // Expanded + Column: both lines wrap at large text sizes instead
            // of overflowing.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: text.labelLarge),
                  Text(value, style: text.bodyLarge),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
