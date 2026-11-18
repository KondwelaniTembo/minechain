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
import '../../../core/widgets/field_errors_mixin.dart';
import '../../../core/widgets/form_message.dart';
import '../../account/presentation/account_screen.dart' show roleLabel;
import '../../auth/domain/auth_state.dart';
import '../../auth/domain/user.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/password_prompt.dart';
import '../domain/account_request.dart';
import 'account_requests_controller.dart';

/// The reject reason's limits (api.md, POST /admin/users/{id}/reject:
/// "3–500 characters" after trimming).
const int rejectReasonMin = 3;
const int rejectReasonMax = 500;

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
  // be shown under its field while it stays open.
  final outcome = await showDialog<RequestAction>(
    context: context,
    builder: (_) => _RejectDialog(request),
  );
  if (outcome != null && context.mounted) {
    _report(context, outcome, AppText.rejected(request.fullName));
  }
}

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

/// The API's name for the one field, as in its `details`.
const _reasonField = 'reason';

/// "Reject this request?" with the reason. It sends the request itself and
/// closes with the outcome once there is nothing more to fix here.
class _RejectDialog extends ConsumerStatefulWidget {
  const _RejectDialog(this.request);

  final AccountRequest request;

  @override
  ConsumerState<_RejectDialog> createState() => _RejectDialogState();
}

class _RejectDialogState extends ConsumerState<_RejectDialog>
    with FieldErrorsMixin<_RejectDialog> {
  final _reason = TextEditingController();
  bool _sending = false;

  /// A failure that is not about the field, shown under it.
  String? _failure;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    // Counted after trimming, as the server counts it.
    if (_reason.text.trim().length < rejectReasonMin) {
      setState(() {
        setFieldErrors({_reasonField: AppText.rejectReasonTooShort});
        _failure = null;
      });
      return;
    }

    setState(() {
      _sending = true;
      setFieldErrors(const {});
      _failure = null;
    });
    final outcome = await ref
        .read(accountRequestsControllerProvider.notifier)
        .reject(widget.request, _reason.text);
    if (!mounted) return;

    switch (outcome) {
      case RequestActionFailed(:final failure, :final fieldErrors):
        // Stay open: the reason can be fixed, or sending tried again.
        setState(() {
          _sending = false;
          final reasonError = fieldErrors[_reasonField];
          if (reasonError != null) {
            setFieldErrors({_reasonField: reasonError});
          } else {
            _failure = failureText(failure);
          }
        });
      case RequestActionDone() ||
          RequestAlreadyHandled() ||
          RequestNeedsPassword() ||
          RequestActionIgnored():
        Navigator.of(context).pop(outcome);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // No closing while the request runs, so its answer has a dialog to
      // come back to.
      canPop: !_sending,
      child: AlertDialog(
        scrollable: true,
        title: const Text(AppText.rejectQuestion),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(AppText.rejectExplanation(widget.request.fullName)),
            const SizedBox(height: AppSizes.spaceM),
            TextField(
              controller: _reason,
              enabled: !_sending,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              // maxLength shows the "12/500" counter under the field and
              // stops typing at 500.
              maxLength: rejectReasonMax,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => clearFieldError(_reasonField),
              decoration: InputDecoration(
                labelText: AppText.rejectReason,
                hintText: AppText.rejectReasonHint,
                errorText: fieldError(_reasonField),
                errorMaxLines: 3,
                hintMaxLines: 3,
              ),
            ),
            const SizedBox(height: AppSizes.spaceS),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ExcludeSemantics(child: Icon(Icons.warning_amber)),
                const SizedBox(width: AppSizes.spaceS),
                const Expanded(child: Text(AppText.rejectReasonWarning)),
              ],
            ),
            if (_failure != null) ...[
              const SizedBox(height: AppSizes.spaceM),
              FormMessage(_failure!),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _sending ? null : () => Navigator.of(context).pop(),
            child: const Text(AppText.cancel),
          ),
          FilledButton(
            onPressed: _sending ? null : _send,
            child: _sending
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SmallSpinner(),
                      SizedBox(width: AppSizes.spaceS),
                      Flexible(child: Text(AppText.sending)),
                    ],
                  )
                : const Text(AppText.reject),
          ),
        ],
      ),
    );
  }
}
