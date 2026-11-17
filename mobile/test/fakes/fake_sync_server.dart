// TEST ONLY: a stand-in for POST /sync/steps (docs/api.md), behind package
// http's MockClient, plus waiting steps to send.
//
// Like the real server it stores each step id once: a resend of a stored
// step comes back `duplicate`. A test can give one step another outcome,
// replace one result entirely, replace a whole answer (no network, a time
// limit passing, 401, 429, 500), hold every answer back, and read every
// batch that was sent. All ids, payloads and signatures are fake.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minechain/core/network/api_client.dart';
import 'package:minechain/core/network/network_providers.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:minechain/features/steps/domain/local_step.dart';

import 'auth_fixtures.dart';

/// A whole answer in place of the normal one.
typedef WholeAnswer =
    Future<http.StreamedResponse> Function(http.BaseRequest request);

class FakeSyncServer {
  /// Step ids already stored, with their transaction id.
  final Map<String, String> stored = {};

  /// Each request's `steps`, in order.
  final List<List<Map<String, Object?>>> batches = [];

  /// Each request's Authorization header.
  final List<String?> authorizations = [];

  /// The time limit ApiClient asked for, per request.
  final List<Duration> timeLimits = [];

  /// Another outcome for one step id, for example
  /// `{'outcome': 'flagged', 'code': 'GPS_ZONE', ...}`. Merged over
  /// `index` and `stepId`.
  final Map<String, Map<String, Object?>> outcomes = {};

  /// Like [outcomes], but used for the first answer only, then normal.
  final Map<String, Map<String, Object?>> outcomesOnce = {};

  /// Replaces one result entirely (for a result that does not match).
  Map<String, Object?>? Function(int index, String stepId)? resultFor;

  /// Whole answers to use, one per request, before the normal behaviour.
  final List<WholeAnswer> next = [];

  /// While set and not completed, every answer waits for it.
  Completer<void>? hold;

  /// Completing it makes the request's time limit pass (see [timedOut]).
  ///
  /// `late`: made on first use, which is the first request, inside the test.
  /// A Future belongs to the zone it was created in, and delivers its result
  /// through that zone's microtask queue. Made in setUp, as the server is,
  /// it would belong to the real zone; testWidgets runs its body in a fake
  /// async zone, and pump() only flushes that zone's queue, so completing it
  /// would never reach the waiting request.
  late final Completer<void> timeLimit = Completer<void>();

  late final MockClient client = MockClient.streaming(_handle);

  /// Overrides that make the app's ApiClient talk to this server. Its time
  /// limit only passes when the test completes [timeLimit], so no timer is
  /// left running.
  List<Override> overrides() => [
    apiClientProvider.overrideWith(
      (ref) async => ApiClient(
        client: client,
        baseUri: Uri.parse('https://api.example.test'),
        sessionEvents: ref.watch(sessionEventsProvider),
        delay: (duration) {
          timeLimits.add(duration);
          return timeLimit.future;
        },
      ),
    ),
  ];

  Future<http.StreamedResponse> _handle(
    http.BaseRequest request,
    http.ByteStream bodyStream,
  ) async {
    final body = await bodyStream.bytesToString();
    final waiting = hold;
    if (waiting != null) await waiting.future;
    if (request.method != 'POST' || request.url.path != '/sync/steps') {
      return _json(404, errorAnswer('NOT_FOUND', 'Route not found'));
    }
    authorizations.add(request.headers['authorization']);
    final steps = [
      for (final step in (jsonDecode(body) as Map)['steps'] as List)
        Map<String, Object?>.from(step as Map),
    ];
    batches.add(steps);

    if (next.isNotEmpty) return next.removeAt(0)(request);

    final results = <Map<String, Object?>>[];
    for (var i = 0; i < steps.length; i++) {
      final stepId = stepIdOf(steps[i]['payload']! as String);
      final custom = resultFor?.call(i, stepId);
      if (custom != null) {
        results.add(custom);
        continue;
      }
      final other = outcomesOnce.remove(stepId) ?? outcomes[stepId];
      if (other != null) {
        results.add({'index': i, 'stepId': stepId, ...other});
        continue;
      }
      final known = stored[stepId];
      if (known != null) {
        results.add(_stored(i, stepId, 'duplicate', known));
      } else {
        final transactionId = 'tx-${stored.length + 1}';
        stored[stepId] = transactionId;
        results.add(_stored(i, stepId, 'created', transactionId));
      }
    }
    return _json(200, jsonEncode({'results': results}));
  }

  static Map<String, Object?> _stored(
    int index,
    String stepId,
    String outcome,
    String transactionId,
  ) => {
    'index': index,
    'stepId': stepId,
    'outcome': outcome,
    'transactionId': transactionId,
    'reviewStatus': 'passed',
  };
}

/// The step_id line of a payload.
String stepIdOf(String payload) => payload
    .split('\n')
    .firstWhere((line) => line.startsWith('step_id='))
    .substring('step_id='.length);

http.StreamedResponse _json(
  int status,
  String body, {
  Map<String, String> headers = const {},
}) => http.StreamedResponse(
  Stream.value(utf8.encode(body)),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

// ---- Whole answers ------------------------------------------------------------

/// No network: the connection cannot be made.
Future<http.StreamedResponse> offline(http.BaseRequest request) async =>
    throw const SocketException('no route to host');

/// Waits for the request's own time limit, then gives up as the real client
/// does. The test completes [FakeSyncServer.timeLimit].
Future<http.StreamedResponse> timedOut(http.BaseRequest request) async {
  await (request as http.Abortable).abortTrigger;
  throw http.RequestAbortedException(request.url);
}

/// An error answer in the API's format.
WholeAnswer refusedWith(
  int status,
  String code, {
  String message = 'Refused.',
  String? retryAfter,
}) =>
    (request) async => _json(
      status,
      errorAnswer(code, message),
      headers: {'retry-after': ?retryAfter},
    );

// ---- Waiting steps ----------------------------------------------------------

const String minerId = '3f2b6c1e-0000-4000-8000-000000000001';
const String otherMinerId = '3f2b6c1e-0000-4000-8000-000000000099';

String stepIdFor(int n) =>
    '6f1d2c3a-0000-4000-8000-${n.toString().padLeft(12, '0')}';

String qrCodeFor(int n) => 'MC-2026-LSK-${n.toString().padLeft(4, '0')}';

/// Saves [count] queued registrations for [actor], numbered from [from],
/// one minute apart from [start], oldest first.
Future<void> queueSteps(
  LocalStepsRepository steps, {
  required int count,
  int from = 1,
  String actor = minerId,
  required DateTime start,
}) async {
  for (var n = from; n < from + count; n++) {
    final stepId = stepIdFor(n);
    await steps.insert(
      NewLocalStep(
        stepId: stepId,
        actorId: actor,
        type: 'registration',
        qrCode: qrCodeFor(n),
        mineral: 'gold',
        weightMg: '1500',
        latitude: '-15.419012',
        longitude: '28.288105',
        capturedAt: '2026-11-16T08:00:00.000Z',
        // Not a valid signed payload: the fake server only reads step_id.
        payload:
            'minechain-step/1/registration\nstep_id=$stepId\n'
            'actor_id=$actor\nqr_code=${qrCodeFor(n)}\n',
        signature: 'MEUCIQFAKE${n}FAKE==',
        keyFingerprint:
            '4d61912d42cfc3d967e27e9179e01054cf7ef9d333a87b414a5ac153f4c93d53',
        gpsAccuracyM: 6,
        createdAt: start.add(Duration(minutes: n - from)),
      ),
    );
  }
}
