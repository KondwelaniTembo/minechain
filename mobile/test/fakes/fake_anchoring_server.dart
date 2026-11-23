// TEST ONLY: a stand-in for GET /admin/anchoring (anchoring status plan, T2;
// docs/api.md "Anchoring administration") behind package http's MockClient.
//
// It answers [status], a healthy running worker by default; a test changes
// any part of it with [anchoringStatusJson]'s named values, replaces the
// answer with [answer], holds every answer back with [hold] (to see the page
// while a request is in flight), and reads every request in [received].
// Every id, hash and address is fake, in api.md's style.

import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minechain/core/network/api_client.dart';
import 'package:minechain/core/network/network_providers.dart';
import 'package:minechain/core/network/session_events.dart';

import 'fake_admin_server.dart' show json200, refusal;

/// Step [n]'s id.
String anchorStepId(int n) =>
    '9d4e5f60-0000-4000-8000-${n.toString().padLeft(12, '0')}';

const fakeRecorder = '0x25E19030C6cdb1e2608819BceF797a23eb0738fA';
const fakeContract = '0x6419cB5268706E2aA4713AB3bCFc336248Ed158a';
final fakeTxHash = '0x${'11' * 32}';

/// One `inFlight` row.
Map<String, Object?> inFlightJson(
  int n, {
  String type = 'handoff',
  int ageSeconds = 600,
  bool stuck = true,
  String? refusalCode = 'FEE_TOO_HIGH',
}) => {
  'stepId': anchorStepId(n),
  'consignmentId': '5c0d7e21-0000-4000-8000-000000000001',
  'type': type,
  'chainTxHash': fakeTxHash,
  'nonce': '41',
  'submittedAt': '2026-11-12T09:50:00.000Z',
  'ageSeconds': ageSeconds,
  'stuck': stuck,
  'lastRefusal': refusalCode == null
      ? null
      : {
          'code': refusalCode,
          'detail': null,
          'error': '$refusalCode: the network fee is above the maximum',
        },
};

/// One `failed` row.
Map<String, Object?> failedJson(
  int n, {
  String type = 'registration',
  String code = 'RPC_UNAVAILABLE',
  int attempts = 3,
  bool retryable = true,
}) => {
  'stepId': anchorStepId(n),
  'consignmentId': '5c0d7e21-0000-4000-8000-000000000002',
  'type': type,
  'code': code,
  'detail': null,
  'attempts': attempts,
  'chainTxHash': null,
  'updatedAt': '2026-11-22T21:00:00.000Z',
  'retryable': retryable,
};

/// One `held` row.
Map<String, Object?> heldJson(
  String qrCode, {
  int pendingSteps = 1,
  int openAlerts = 1,
}) => {
  'consignmentId': '5c0d7e21-0000-4000-8000-000000000003',
  'qrCode': qrCode,
  'pendingSteps': pendingSteps,
  'openAlerts': openAlerts,
};

/// A whole answer. The defaults are a healthy worker with nothing waiting,
/// as production looked on 23 Nov; anything can be changed.
Map<String, Object?> anchoringStatusJson({
  String state = 'running',
  Map<String, Object?>? lastTick = const {
    'at': '2026-11-23T00:41:00.000Z',
    'outcome': 'idle',
    'code': null,
    'stepId': null,
  },
  String? recorderAddress = fakeRecorder,
  String? contractAddress = fakeContract,
  Map<String, Object?> counts = const {
    'pending': 0,
    'submitted': 0,
    'confirmed': 41,
    'failed': 0,
  },
  List<Map<String, Object?>> inFlight = const [],
  List<Map<String, Object?>> failed = const [],
  int? oldestAgeSeconds,
  int onHeldConsignments = 0,
  int behindFailedStep = 0,
  List<Map<String, Object?>> held = const [],
  String? lastConfirmedAt = '2026-11-21T00:27:12.000Z',
  List<Map<String, Object?>> problems = const [],
}) => {
  'worker': {
    'state': state,
    'startedAt': '2026-11-22T22:31:00.000Z',
    'preflight': {
      'at': '2026-11-22T22:31:00.000Z',
      'passed': true,
      'retrying': false,
      'checks': <Object?>[],
    },
    'lastTick': lastTick,
    'recorderAddress': recorderAddress,
    'contractAddress': contractAddress,
  },
  'counts': counts,
  'inFlight': inFlight,
  'failed': failed,
  'pending': {
    'oldestReceivedAt': oldestAgeSeconds == null
        ? null
        : '2026-11-23T00:20:00.000Z',
    'oldestAgeSeconds': oldestAgeSeconds,
    'onHeldConsignments': onHeldConsignments,
    'behindFailedStep': behindFailedStep,
    'sendableNow': null,
  },
  'held': held,
  'lastConfirmed': lastConfirmedAt == null
      ? null
      : {'stepId': anchorStepId(3), 'anchoredAt': lastConfirmedAt},
  'lastSubmitted': null,
  'problems': problems,
};

/// api.md's own example: a step stuck behind a fee above the cap.
Map<String, Object?> stuckExampleJson() => anchoringStatusJson(
  lastTick: const {
    'at': '2026-11-12T09:59:45.000Z',
    'outcome': 'waiting',
    'code': null,
    'stepId': null,
  },
  counts: const {'pending': 2, 'submitted': 1, 'confirmed': 41, 'failed': 0},
  inFlight: [inFlightJson(1)],
  oldestAgeSeconds: 1200,
  lastConfirmedAt: '2026-11-12T09:49:36.000Z',
  problems: const [
    {
      'code': 'STUCK_SUBMITTED',
      'message':
          'A sent step has not moved for more than 5 minutes. Nothing else '
          'can be anchored until it does.',
    },
  ],
);

typedef AnchoringAnswer = FutureOr<http.Response> Function(
  http.Request request,
);

class FakeAnchoringServer {
  FakeAnchoringServer([Map<String, Object?>? status])
    : status = status ?? anchoringStatusJson();

  /// What GET /admin/anchoring answers.
  Map<String, Object?> status;

  /// Replaces the answer when set (a refusal, a malformed body).
  AnchoringAnswer? answer;

  /// While set, every answer waits for it.
  Completer<void>? hold;

  final List<http.Request> received = [];

  late final MockClient client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    received.add(request);
    final waiting = hold;
    if (waiting != null) await waiting.future;

    final path = request.url.pathSegments;
    if (request.method != 'GET' ||
        path.length != 2 ||
        path[0] != 'admin' ||
        path[1] != 'anchoring') {
      return refusal(404, 'NOT_FOUND', 'Route not found');
    }
    return await (answer?.call(request) ?? json200(status));
  }

  /// Overrides that make the app's ApiClient talk to this server. Requests
  /// never time out, so no timer is left running at the end of a test.
  List<Override> overrides() => [
    apiClientProvider.overrideWith(
      (ref) async => ApiClient(
        client: client,
        baseUri: Uri.parse('https://api.example.test'),
        sessionEvents: ref.watch(sessionEventsProvider),
        delay: (_) => Completer<void>().future,
      ),
    ),
  ];

  /// An ApiClient on this server without Riverpod, for plain unit tests.
  ApiClient apiClient() => ApiClient(
    client: client,
    baseUri: Uri.parse('https://api.example.test'),
    sessionEvents: SessionEvents(),
    delay: (_) => Completer<void>().future,
  );
}
