// POST /sync/steps (api.md): one batch of saved steps, exactly as they were
// signed. Nothing here is logged; the payloads and signatures go only into
// the request body.

import '../../../core/errors/app_failure.dart';
import '../../../core/network/api_client.dart';
import '../../steps/domain/local_step.dart';

/// The time limit for one sync request (plan M6, approved point 5). A free
/// Render service takes about 50–60 s to wake after 15 idle minutes
/// (deployment.md), and the request that wakes it must not give up first.
/// 90 s is the foundation's wake-up health check limit, for the same reason.
/// Giving up early is safe anyway: a resend comes back `duplicate`.
const Duration syncTimeout = Duration(seconds: 90);

class SyncApi {
  SyncApi(this._api);
  final ApiClient _api;

  /// Sends [steps] (1 to 50) and returns the server's `results` list, one
  /// per step, in the order sent. The stored payload and signature go
  /// exactly as saved, and nothing else (the server refuses other fields).
  ///
  /// Throws an [AppFailure] for a whole-request failure, and [BadResponse]
  /// for a 200 without a `results` list.
  Future<List<Object?>> send({
    required String token,
    required List<LocalStep> steps,
  }) async {
    final body = await _api.post(
      const ['sync', 'steps'],
      token: token,
      timeout: syncTimeout,
      body: {
        'steps': [
          for (final step in steps)
            {'payload': step.payload, 'signature': step.signature},
        ],
      },
    );
    if (body is Map && body['results'] is List) {
      return body['results'] as List<Object?>;
    }
    throw const BadResponse(status: 200);
  }
}
