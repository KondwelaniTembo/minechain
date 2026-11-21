// The administrator's "with a reason" dialog: Reject a request (A1), and
// Suspend, Reset device key and Delete an account (admin accounts plan,
// T4). Moved here from account_requests_screen.dart, where it was "Reject"
// only, with its words passed in; "Account requests" behaves exactly as
// before.
//
// It sends the request itself, through [send], and stays open while the
// answer can still be acted on: a reason the server refused (shown under the
// field), or any other refusal (shown under it, the reason kept). It closes
// with the outcome once there is nothing more to fix here.
//
// Every reason is 3–500 characters after trimming (api.md, "Reasons") and
// is kept for ever in the append-only audit log, so the warning is always
// shown.

import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/field_errors_mixin.dart';
import '../../../core/widgets/form_message.dart';

/// The reason's limits (api.md, "Reasons": "3 to 500 characters after
/// surrounding spaces are trimmed").
const int reasonMin = 3;
const int reasonMax = 500;

/// What is wrong after a send: a sentence under the field (the server's
/// `reason` detail), or one under the dialog (any other refusal).
class ReasonProblem {
  const ReasonProblem({this.underField, this.underDialog});

  final String? underField;
  final String? underDialog;
}

class ReasonDialog<T> extends StatefulWidget {
  const ReasonDialog({
    required this.title,
    required this.explanation,
    required this.actionLabel,
    required this.hint,
    required this.send,
    required this.problemOf,
    this.destructive = false,
    super.key,
  });

  final String title;
  final String explanation;
  final String actionLabel;
  final String hint;

  /// Sends the reason as typed (the repository trims it).
  final Future<T> Function(String reason) send;

  /// Null when [send]'s outcome closes the dialog; otherwise what to show.
  final ReasonProblem? Function(T outcome) problemOf;

  /// The button in the error colour, for an action that cannot be undone.
  final bool destructive;

  @override
  State<ReasonDialog<T>> createState() => _ReasonDialogState<T>();
}

/// The API's name for the one field, as in its `details`.
const _reasonField = 'reason';

class _ReasonDialogState<T> extends State<ReasonDialog<T>>
    with FieldErrorsMixin<ReasonDialog<T>> {
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
    if (_reason.text.trim().length < reasonMin) {
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
    final outcome = await widget.send(_reason.text);
    if (!mounted) return;

    final problem = widget.problemOf(outcome);
    if (problem == null) {
      Navigator.of(context).pop(outcome);
      return;
    }
    // Stay open: the reason can be fixed, or sending tried again.
    setState(() {
      _sending = false;
      final underField = problem.underField;
      if (underField != null) {
        setFieldErrors({_reasonField: underField});
      } else {
        _failure = problem.underDialog;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      // No closing while the request runs, so its answer has a dialog to
      // come back to.
      canPop: !_sending,
      child: AlertDialog(
        scrollable: true,
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.explanation),
            const SizedBox(height: AppSizes.spaceM),
            TextField(
              controller: _reason,
              enabled: !_sending,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              // maxLength shows the "12/500" counter under the field and
              // stops typing at 500.
              maxLength: reasonMax,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => clearFieldError(_reasonField),
              decoration: InputDecoration(
                labelText: AppText.rejectReason,
                hintText: widget.hint,
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
            style: widget.destructive
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            child: _sending
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: AppSizes.spaceS),
                      Flexible(child: Text(AppText.sending)),
                    ],
                  )
                : Text(widget.actionLabel),
          ),
        ],
      ),
    );
  }
}
