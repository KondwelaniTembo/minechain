// The rules for reading the server's sync answers (plan §3, api.md
// "POST /sync/steps"). Plain Dart: no Flutter, no database, no network.
//
// The app branches on `outcome` and `code`, never on `message`. The message
// is kept only to show it as given.

import '../../../core/errors/api_codes.dart';
import '../../steps/domain/local_step.dart';

/// How long to wait before sending a deferred step again, after its
/// [deferrals]th deferral (1 for the first): 1, 2, 4, 8, 16, 32 minutes,
/// then every 60 minutes (plan §3). A tap on Send ignores it.
Duration deferredBackoff(int deferrals) {
  if (deferrals >= 7) return const Duration(minutes: 60);
  final step = deferrals < 1 ? 1 : deferrals;
  return Duration(minutes: 1 << (step - 1));
}

/// Turns the server's result number [index] into the change to write for
/// [sent], the step at that place in the request. Null when the result
/// cannot be used: not this step, an unknown outcome, or a field missing.
/// The row then stays as it was and is sent again later (a resend is safe,
/// plan §3), and the caller counts it as an app problem.
///
/// The step is matched by position AND checked by `stepId`. One exception:
/// a `rejected` result may have `stepId: null` (api.md: "or null if the
/// payload could not be read"); then the position alone decides, because
/// the server answers in the order sent.
///
/// [now] is when the answer arrived, for a deferred step's next attempt.
StepSyncUpdate? updateFromResult(
  Object? result, {
  required int index,
  required LocalStep sent,
  required DateTime now,
}) {
  if (result is! Map) return null;
  if (result['index'] != index) return null;

  String? text(String key) {
    final value = result[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  final stepId = result['stepId'];
  final sameStep = stepId == sent.stepId;
  final code = text('code');
  final message = result['message'] is String ? result['message'] as String : '';
  final transactionId = text('transactionId');
  final reviewStatus = text('reviewStatus');

  switch (result['outcome']) {
    case 'created' || 'duplicate':
      // `duplicate` is the answer to a resend of a stored step: success.
      if (!sameStep || transactionId == null || reviewStatus == null) {
        return null;
      }
      return StepSynced(
        sent.stepId,
        reviewStatus: reviewStatus,
        transactionId: transactionId,
      );
    case 'flagged':
      if (!sameStep ||
          code == null ||
          transactionId == null ||
          reviewStatus == null) {
        return null;
      }
      return StepFlagged(
        sent.stepId,
        code: code,
        message: message,
        reviewStatus: reviewStatus,
        transactionId: transactionId,
      );
    case 'rejected':
      if ((!sameStep && stepId != null) || code == null) return null;
      return StepRejected(sent.stepId, code: code, message: message);
    case 'deferred':
      if (!sameStep || code == null) return null;
      return StepDeferred(
        sent.stepId,
        code: code,
        message: message,
        nextAttemptAt: now.add(deferredBackoff(sent.attempts + 1)),
      );
    default:
      return null;
  }
}

/// Whether [update] says the account has no device key on the server yet:
/// the key is sent, and the step tried once more in the same run (plan §3).
bool isNoDeviceKey(StepSyncUpdate update) =>
    update is StepDeferred && update.code == ApiCodes.noDeviceKey;
