// "Accounts": the administrator's list of every account by status (admin
// accounts plan §4.1, T2; FR-10, Scope (3)).
//
// Five lists behind one row of chips (Q2): "Active" (the default),
// "Suspended", "Invited", "Rejected", "Deleted". Pending requests are on
// "Account requests" (Q5). Each card says who it is, the role, and why the
// account is in its status (the reason, or an invited account's code). A tap
// opens the account (T3); coming back reads the list again, so a change just
// made is never shown wrongly. "Create account" (T5) is the floating button.
//
// The server checks the role on every request; the router only keeps other
// roles from opening this page.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/clock.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../account/presentation/account_screen.dart' show roleLabel;
import '../../alerts/presentation/alert_widgets.dart'
    show AlertInfoLine, AlertStateMessage, SmallSpinner;
import '../../auth/domain/user.dart' show AccountStatus;
import '../../auth/presentation/password_prompt.dart';
import '../../steps/presentation/saved_work_gate.dart' show backOrHome;
import '../domain/admin_account.dart';
import 'account_page_controller.dart' show openedAccountProvider;
import 'account_words.dart';
import 'accounts_list_controller.dart';

class AccountsScreen extends ConsumerStatefulWidget {
  const AccountsScreen({super.key});

  @override
  ConsumerState<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends ConsumerState<AccountsScreen> {
  AccountStatus _status = AccountStatus.active;

  AccountsListController get _controller =>
      ref.read(accountsListControllerProvider(_status).notifier);

  Future<void> _refresh() async {
    final failure = await _controller.refresh();
    if (failure != null && mounted) _say(context, failureText(failure));
  }

  /// Opens one account; the list is read again when it closes.
  Future<void> _open(AdminAccount account) async {
    ref.read(openedAccountProvider.notifier).open(account);
    await context.push(AppRoutes.adminAccount);
    if (mounted) await _refresh();
  }

  /// Opens "Create account". A created account is invited, so the list
  /// switches to "Invited", where it now is.
  Future<void> _create() async {
    final created = await context.push<bool>(AppRoutes.adminCreateAccount);
    if (!mounted) return;
    if (created == true && _status != AccountStatus.invited) {
      // A new family member is built for "Invited", and it fetches itself.
      setState(() => _status = AccountStatus.invited);
    } else {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(accountsListControllerProvider(_status));
    final canRefresh = switch (state) {
      AccountsLoading() => false,
      AccountsLoaded(:final loadingMore) => !loadingMore,
      _ => true,
    };

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () => backOrHome(context, AppRoutes.admin),
        ),
        title: const Text(AppText.accounts),
        actions: [
          IconButton(
            tooltip: AppText.refreshList,
            icon: const Icon(Icons.refresh),
            onPressed: canRefresh ? _refresh : null,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.person_add),
        label: const Text(AppText.createAccount),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            // Scrollable even when short, so the list can always be pulled
            // down to refresh.
            physics: const AlwaysScrollableScrollPhysics(),
            // Room at the bottom, so the floating button never covers the
            // last card or "Show more".
            padding: const EdgeInsets.fromLTRB(
              AppSizes.spaceM,
              AppSizes.spaceM,
              AppSizes.spaceM,
              96,
            ),
            children: [
              for (final child in [
                _StatusChips(
                  selected: _status,
                  onSelected: (status) => setState(() => _status = status),
                ),
                const SizedBox(height: AppSizes.spaceM),
                ..._body(state),
              ])
                Center(
                  child: ConstrainedBox(
                    // A readable width on a turned phone.
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: child,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body(AccountsListState state) => switch (state) {
    AccountsLoading() => const [_Loading()],
    AccountsNeedPassword() => [
      AlertStateMessage(
        icon: Icons.key,
        text: AppText.accountsNeedPassword,
        action: FilledButton(
          onPressed: () async {
            final controller = _controller;
            if (await showPasswordPrompt(context)) await controller.refresh();
          },
          child: const Text(AppText.enterYourPassword),
        ),
      ),
    ],
    AccountsFailed(:final failure) => [
      AlertStateMessage(
        icon: failure is NoConnection ? Icons.wifi_off : Icons.error_outline,
        text: failureText(failure),
        // No casual "Try again" for an unsafe connection: it may mean
        // someone is intercepting the network.
        action: failure is InsecureConnection
            ? null
            : FilledButton(
                onPressed: () => _controller.refresh(),
                child: const Text(AppText.tryAgain),
              ),
      ),
    ],
    AccountsLoaded(accounts: []) => [
      AlertStateMessage(
        icon: Icons.inbox,
        text: AppText.noAccounts(statusWord(_status)),
      ),
    ],
    final AccountsLoaded loaded => [
      Padding(
        padding: const EdgeInsets.only(bottom: AppSizes.spaceS),
        child: Text(
          AppText.accountsCount(
            status: statusWord(_status),
            shown: loaded.accounts.length,
            total: loaded.total,
          ),
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      for (final account in loaded.accounts)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSizes.spaceM),
          child: AccountCard(
            key: ValueKey(account.id),
            account: account,
            now: ref.read(clockProvider)(),
            onTap: () => _open(account),
          ),
        ),
      if (loaded.hasMore)
        OutlinedButton.icon(
          onPressed: loaded.loadingMore
              ? null
              : () async {
                  final failure = await _controller.loadMore();
                  if (failure != null && mounted) {
                    _say(context, failureText(failure));
                  }
                },
          icon: loaded.loadingMore
              ? const SmallSpinner()
              : const Icon(Icons.expand_more),
          label: const Text(AppText.showMore),
        ),
    ],
  };
}

void _say(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Q2: five chips, one status at a time. In a Wrap, so at large text they go
/// onto more lines instead of being cut or scrolling sideways.
class _StatusChips extends StatelessWidget {
  const _StatusChips({required this.selected, required this.onSelected});

  final AccountStatus selected;
  final ValueChanged<AccountStatus> onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: AppText.accountsShowing,
      child: Wrap(
        spacing: AppSizes.spaceS,
        runSpacing: AppSizes.spaceS,
        children: [
          for (final status in listedStatuses)
            ChoiceChip(
              label: Text(statusChipLabel(status)),
              selected: status == selected,
              onSelected: (_) => onSelected(status),
            ),
        ],
      ),
    );
  }
}

/// One account in the list. Public so the account page's tests can find it.
class AccountCard extends StatelessWidget {
  const AccountCard({
    required this.account,
    required this.now,
    required this.onTap,
    super.key,
  });

  final AdminAccount account;

  /// The time now, in UTC, for an invited account's code line.
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final detail = statusDetail(account, now);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(account.fullName, style: text.titleMedium),
                  ),
                  const ExcludeSemantics(child: Icon(Icons.chevron_right)),
                ],
              ),
              const SizedBox(height: AppSizes.spaceS),
              AlertInfoLine(icon: Icons.badge, text: account.username),
              AlertInfoLine(
                icon: roleIcon(account.role),
                text: roleLabel(account.role),
              ),
              // Only the three self-registering roles have a licence field.
              if (keyHoldingRoles.contains(account.role))
                AlertInfoLine(
                  icon: Icons.verified,
                  text: account.licenceNumber ?? AppText.noLicenceNumber,
                ),
              if (detail != null)
                AlertInfoLine(icon: statusIcon(account.status), text: detail),
            ],
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSizes.spaceXl),
      child: Column(
        children: [
          CircularProgressIndicator(),
          SizedBox(height: AppSizes.spaceM),
          Text(AppText.loadingAccounts, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
