// "Account requests": the administrator's list of pending requests from
// miners, transporters and buyers, with Approve and Reject (plan A1, FR-12).
//
// The screen decides nothing about the server. It shows the controller's
// state, asks before acting, and turns each outcome into one plain sentence.
// The server checks the role on every request; the router only keeps
// non-administrators from opening this page.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../account/presentation/account_screen.dart' show roleLabel;
import '../../auth/domain/auth_state.dart';
import '../../auth/domain/user.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/password_prompt.dart';
import '../domain/account_request.dart';
import 'account_requests_controller.dart';
import 'reason_dialog.dart';

/// The reject reason's limits (api.md, POST /admin/users/{id}/reject:
/// "3–500 characters" after trimming), the same as every reason's.
const int rejectReasonMin = reasonMin;
const int rejectReasonMax = reasonMax;

class AccountRequestsScreen extends ConsumerWidget {
  const AccountRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(accountRequestsControllerProvider);
    final canRefresh = switch (state) {
      RequestsLoading() => false,
      RequestsLoaded(:final busy) => !busy,
      _ => true,
    };

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => _back(context)),
        title: const Text(AppText.accountRequests),
        actions: [
          // The same as pulling the list down, for people who cannot easily
          // make that gesture, or do not know it.
          IconButton(
            tooltip: AppText.refreshList,
            icon: const Icon(Icons.refresh),
            onPressed: canRefresh ? () => _refresh(context, ref) : null,
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _refresh(context, ref),
          child: _Body(state: state),
        ),
      ),
    );
  }

  void _back(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.admin);
    }
  }
}

/// Pull-to-refresh and the refresh button. A failure while a list is on
/// screen keeps the list and says so briefly.
Future<void> _refresh(BuildContext context, WidgetRef ref) async {
  final failure = await ref
      .read(accountRequestsControllerProvider.notifier)
      .refresh();
  if (failure != null && context.mounted) {
    _say(context, failureText(failure));
  }
}

void _say(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Makes sure the token is usable before an action (decision Q2): asks for
/// the password if it has expired. False if the user cancelled.
Future<bool> _signedInFirst(BuildContext context, WidgetRef ref) async {
  return switch (ref.read(authControllerProvider)) {
    SignedIn() => true,
    SignedInNeedsPassword() => await showPasswordPrompt(context),
    SignedOut() || AuthUnknown() => false,
  };
}

/// One sentence for what an approve or reject came to.
void _report(BuildContext context, RequestAction outcome, String done) {
  final message = switch (outcome) {
    RequestActionDone() => done,
    RequestAlreadyHandled() => AppText.requestAlreadyHandled,
    RequestActionFailed(:final failure) => failureText(failure),
    RequestNeedsPassword() => AppText.sessionExpired,
    RequestActionIgnored() => null,
  };
  if (message != null) _say(context, message);
}

Future<void> _approve(
  BuildContext context,
  WidgetRef ref,
  AccountRequest request,
) async {
  // Read before any await: the screen may be gone afterwards.
  final controller = ref.read(accountRequestsControllerProvider.notifier);
  if (!await _signedInFirst(context, ref) || !context.mounted) return;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => _ApproveDialog(request),
  );
  if (confirmed != true) return;

  final outcome = await controller.approve(request);
  if (context.mounted) {
    _report(context, outcome, AppText.approved(request.fullName));
  }
}

Future<void> _reject(
  BuildContext context,
  WidgetRef ref,
  AccountRequest request,
) async {
  if (!await _signedInFirst(context, ref) || !context.mounted) return;

  // The dialog sends the request itself, so the server's field errors can
  // be shown under its field while it stays open. Read before the dialog:
  // the screen keeps the controller alive meanwhile.
  final controller = ref.read(accountRequestsControllerProvider.notifier);
  final outcome = await showDialog<RequestAction>(
    context: context,
    builder: (_) => ReasonDialog<RequestAction>(
      title: AppText.rejectQuestion,
      explanation: AppText.rejectExplanation(request.fullName),
      actionLabel: AppText.reject,
      hint: AppText.rejectReasonHint,
      send: (reason) => controller.reject(request, reason),
      problemOf: _rejectProblem,
    ),
  );
  if (outcome != null && context.mounted) {
    _report(context, outcome, AppText.rejected(request.fullName));
  }
}

/// What keeps the reject dialog open: only a refusal. Done, already handled,
/// needs-password and ignored all close it, as before.
ReasonProblem? _rejectProblem(RequestAction outcome) => switch (outcome) {
  RequestActionFailed(:final failure, :final fieldErrors) =>
    fieldErrors['reason'] != null
        ? ReasonProblem(underField: fieldErrors['reason'])
        : ReasonProblem(underDialog: failureText(failure)),
  _ => null,
};

// ---- The body for each state ---------------------------------------------

class _Body extends ConsumerWidget {
  const _Body({required this.state});

  final RequestsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Widget> children = switch (state) {
      RequestsLoading() => const [_Loading()],
      RequestsNeedPassword() => [
        _StateMessage(
          icon: Icons.key,
          text: AppText.requestsNeedPassword,
          action: FilledButton(
            onPressed: () async {
              final controller = ref.read(
                accountRequestsControllerProvider.notifier,
              );
              if (await showPasswordPrompt(context)) await controller.refresh();
            },
            child: const Text(AppText.enterYourPassword),
          ),
        ),
      ],
      RequestsFailed(:final failure) => [
        _StateMessage(
          icon: failure is NoConnection ? Icons.wifi_off : Icons.error_outline,
          text: failureText(failure),
          // No casual "Try again" for an unsafe connection (plan section
          // 3.2): it may mean someone is intercepting the network.
          action: failure is InsecureConnection
              ? null
              : FilledButton(
                  onPressed: () => ref
                      .read(accountRequestsControllerProvider.notifier)
                      .refresh(),
                  child: const Text(AppText.tryAgain),
                ),
        ),
      ],
      RequestsLoaded(requests: []) => const [
        _StateMessage(icon: Icons.inbox, text: AppText.noRequestsWaiting),
      ],
      final RequestsLoaded loaded => _list(context, ref, loaded),
    };

    // A ListView in every state, scrollable even when short, so the list can
    // always be pulled down to refresh (RefreshIndicator needs a scrollable).
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSizes.spaceM),
      children: [
        for (final child in children)
          Center(
            child: ConstrainedBox(
              // A readable width on a turned phone.
              constraints: const BoxConstraints(maxWidth: 560),
              child: child,
            ),
          ),
      ],
    );
  }

  List<Widget> _list(
    BuildContext context,
    WidgetRef ref,
    RequestsLoaded loaded,
  ) {
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: AppSizes.spaceS),
        child: Text(
          AppText.requestsCount(
            shown: loaded.requests.length,
            total: loaded.total,
          ),
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      for (final request in loaded.requests)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSizes.spaceM),
          child: _RequestCard(
            // A key per request: when a row leaves, Flutter keeps every other
            // card matched to its own request.
            key: ValueKey(request.id),
            request: request,
            busy: loaded.busyId == request.id,
            enabled: !loaded.busy,
            onApprove: () => _approve(context, ref, request),
            onReject: () => _reject(context, ref, request),
          ),
        ),
      if (loaded.hasMore)
        OutlinedButton.icon(
          onPressed: loaded.busy
              ? null
              : () async {
                  final failure = await ref
                      .read(accountRequestsControllerProvider.notifier)
                      .loadMore();
                  if (failure != null && context.mounted) {
                    _say(context, failureText(failure));
                  }
                },
          icon: loaded.loadingMore
              ? const _SmallSpinner()
              : const Icon(Icons.expand_more),
          label: const Text(AppText.showMore),
        ),
    ];
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
          Text(AppText.loadingRequests, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

/// A large icon, a sentence and, optionally, a button: the empty, failed and
/// needs-password states.
class _StateMessage extends StatelessWidget {
  const _StateMessage({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSizes.spaceXl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeSemantics(child: Icon(icon, size: AppSizes.tileIcon)),
          const SizedBox(height: AppSizes.spaceM),
          // liveRegion: TalkBack reads the new state out when it appears.
          Semantics(
            liveRegion: true,
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: AppSizes.spaceM),
            action!,
          ],
        ],
      ),
    );
  }
}

// ---- One request ------------------------------------------------------------

IconData _roleIcon(Role role) => switch (role) {
  Role.miner => Icons.landscape,
  Role.transporter => Icons.local_shipping,
  Role.buyer => Icons.storefront,
  Role.officer => Icons.policy,
  Role.admin => Icons.admin_panel_settings,
};

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    super.key,
    required this.request,
    required this.busy,
    required this.enabled,
    required this.onApprove,
    required this.onReject,
  });

  final AccountRequest request;

  /// This request is being approved or rejected.
  final bool busy;

  /// No action is running anywhere in the list.
  final bool enabled;

  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.spaceM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(request.fullName, style: text.titleMedium),
            const SizedBox(height: AppSizes.spaceS),
            _InfoLine(icon: Icons.badge, text: request.username),
            _InfoLine(
              icon: _roleIcon(request.role),
              text: roleLabel(request.role),
            ),
            _InfoLine(
              icon: Icons.verified,
              text: request.licenceNumber ?? AppText.noLicenceNumber,
            ),
            _InfoLine(
              icon: Icons.event,
              // The phone's own time zone, for the person reading it.
              text: AppText.requestedOn(request.requestedAt.toLocal()),
            ),
            const SizedBox(height: AppSizes.spaceM),
            // Wrap, not Row: at large text the two buttons go one under the
            // other instead of running off the card.
            Wrap(
              spacing: AppSizes.spaceS,
              runSpacing: AppSizes.spaceS,
              children: [
                FilledButton.icon(
                  onPressed: enabled ? onApprove : null,
                  icon: busy ? const _SmallSpinner() : const Icon(Icons.check),
                  label: const Text(AppText.approve),
                ),
                OutlinedButton.icon(
                  onPressed: enabled ? onReject : null,
                  icon: const Icon(Icons.close),
                  label: const Text(AppText.reject),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSizes.spaceXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 20)),
          const SizedBox(width: AppSizes.spaceS),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _SmallSpinner extends StatelessWidget {
  const _SmallSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}

// ---- Dialogs ------------------------------------------------------------------

/// "Approve this request?", naming the person and the role. Answers true
/// (Approve), false (Cancel) or null (dismissed).
class _ApproveDialog extends StatelessWidget {
  const _ApproveDialog(this.request);

  final AccountRequest request;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text(AppText.approveQuestion),
      content: Text(
        AppText.approveExplanation(request.fullName, roleLabel(request.role)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text(AppText.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text(AppText.approve),
        ),
      ],
    );
  }
}
