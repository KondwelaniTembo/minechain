// TEST ONLY: a stand-in for GET /consignments/by-qr/{qrCode} (docs/api.md),
// behind package http's MockClient. By default it knows one consignment and
// answers 404 CONSIGNMENT_NOT_FOUND for any other code, as the real server
// does.
//
// A test can replace the answer, hold it back (to see the screen while the
// check runs), and read every request that was sent. All values are fake, in
// api.md's style.

import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minechain/core/network/api_client.dart';
import 'package:minechain/core/network/network_providers.dart';
import 'package:minechain/core/network/session_events.dart';

import 'fake_admin_server.dart' show json200, refusal;

/// The code the fake server knows.
const String knownQrCode = 'MC-2026-LSK-0001';

const String fakeTxHash =
    '0xccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0';

/// One step as an officer sees it: every field. Tests remove what a role
/// may not see, following api.md's "What each viewer sees".
Map<String, Object?> checkedStepJson({
  String type = 'registration',
  String role = 'miner',
  String check = 'match',
  int n = 1,
}) => {
  'id': '9d4e5f60-0000-4000-8000-${n.toString().padLeft(12, '0')}',
  'type': type,
  'byYou': false,
  'actor': {'role': role, 'username': 'demo_${role}_$n'},
  'weightMg': '1500000',
  'location': {'latitude': '-15.419012', 'longitude': '28.288105'},
  'zoneName': 'ZCAS Campus (demo)',
  'capturedAt': '2026-11-10T08:00:00.000Z',
  'receivedAt': '2026-11-10T08:05:01.118Z',
  'anchor': {'status': 'confirmed', 'chainTxHash': fakeTxHash},
  'check': {'result': check},
  'reviewStatus': 'passed',
  'alerts': <Object?>[],
};

/// A whole 200 body.
Map<String, Object?> consignmentAnswerJson({
  String qrCode = knownQrCode,
  String stage = 'in_transit',
  bool held = false,
  bool weightsHidden = false,
  List<Map<String, Object?>>? steps,
}) => {
  'consignment': {
    'id': '5c0d7e21-0000-4000-8000-000000000001',
    'qrCode': qrCode,
    'mineral': 'gold',
    'stage': stage,
    'held': held,
    'weightsHidden': weightsHidden,
  },
  'steps':
      steps ??
      [
        checkedStepJson(),
        checkedStepJson(type: 'handoff', role: 'transporter', n: 2),
      ],
};

typedef CheckAnswer = FutureOr<http.Response> Function(http.Request request);

class FakeCheckServer {
  FakeCheckServer();

  /// Every request sent, oldest first.
  final List<http.Request> requests = [];

  /// The answer to each request. Replace it to test a refusal or a
  /// different consignment.
  late CheckAnswer answer = _knownOnly;

  /// When set, every answer waits for it.
  Completer<void>? hold;

  late final http.Client client = MockClient((request) async {
    requests.add(request);
    final waiting = hold;
    if (waiting != null) await waiting.future;
    return answer(request);
  });

  /// The code the app asked for, decoded from the last path segment.
  String get lastQrCode => requests.last.url.pathSegments.last;

  static http.Response _knownOnly(http.Request request) {
    final segments = request.url.pathSegments;
    if (segments.length == 3 &&
        segments[0] == 'consignments' &&
        segments[1] == 'by-qr' &&
        segments[2] == knownQrCode) {
      return json200(consignmentAnswerJson());
    }
    return refusal(
      404,
      'CONSIGNMENT_NOT_FOUND',
      'No consignment has this QR code.',
    );
  }

  /// Overrides that make the app's ApiClient talk to this server. Requests
  /// never time out, so no timer is left running at the end of a test.
  List<Override> overrides() => [
    apiClientProvider.overrideWith(
      (ref) async => ApiClient(
        client: client,
        baseUri: Uri.parse('https://api.example.test'),
        // The app's own session events, so a 401 here reaches the app's
        // session handling as a real one would.
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
