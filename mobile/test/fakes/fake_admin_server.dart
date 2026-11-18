// TEST ONLY: a stand-in for the three admin endpoints the "Account requests"
// screen uses (docs/api.md), behind package http's MockClient. It keeps a
// list of pending requests, answers GET /admin/users from it, and removes a
// request when it is approved or rejected, as the real server would.
//
// A test can replace any answer, hold every answer back (to see the screen
// while a request is in flight), and read every request that was sent.
// All names and ids are fake, in api.md's style.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minechain/core/network/api_client.dart';
import 'package:minechain/core/network/network_providers.dart';
import 'package:minechain/core/network/session_events.dart';

import 'auth_fixtures.dart';

/// One pending request in the API's admin view. [n] makes the id, username
/// and name unique.
Map<String, Object?> pendingUserJson(
  int n, {
  String role = 'miner',
  String? licenceNumber = 'ZM-ASM-0042',
  String? fullName,
}) => {
  'id': '3f2b6c1e-0000-4000-8000-${(100 + n).toString().padLeft(12, '0')}',
  'username': 'demo_user_$n',
  'fullName': fullName ?? 'Demo Person $n',
  'licenceNumber': licenceNumber,
  'role': role,
  'status': 'pending',
  'statusReason': null,
  'approvedBy': null,
  'approvedAt': null,
  'createdAt': '2026-11-05T09:00:00.000Z',
  'updatedAt': '2026-11-05T09:00:00.000Z',
  'publicKeyFingerprint': null,
  'activationExpiresAt': null,
};

typedef Answer = FutureOr<http.Response> Function(http.Request request);

class FakeAdminServer {
  FakeAdminServer([List<Map<String, Object?>>? pending])
    : pending = pending ?? [pendingUserJson(1), pendingUserJson(2)];

  /// The pending requests, oldest first, as the server holds them.
  final List<Map<String, Object?>> pending;

  /// Every request received, in order.
  final List<http.Request> received = [];

  /// Replace an endpoint's answer. Null means the normal behaviour.
  Answer? listAnswer;
  Answer? approveAnswer;
  Answer? rejectAnswer;

  /// While set and not completed, every answer waits for it.
  Completer<void>? hold;

  List<http.Request> get lists =>
      received.where((r) => r.method == 'GET').toList();
  List<http.Request> get approves =>
      received.where((r) => r.url.path.endsWith('/approve')).toList();
  List<http.Request> get rejects =>
      received.where((r) => r.url.path.endsWith('/reject')).toList();

  late final MockClient client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    received.add(request);
    final waiting = hold;
    if (waiting != null) await waiting.future;

    final path = request.url.pathSegments;
    if (request.method == 'GET' &&
        path.length == 2 &&
        path[0] == 'admin' &&
        path[1] == 'users') {
      return await (listAnswer?.call(request) ?? _page(request));
    }
    if (request.method == 'POST' && path.length == 4 && path[0] == 'admin') {
      final id = path[2];
      switch (path[3]) {
        case 'approve':
          return await (approveAnswer?.call(request) ?? _decide(id, 'active'));
        case 'reject':
          return await (rejectAnswer?.call(request) ?? _decide(id, 'rejected'));
      }
    }
    return http.Response(errorAnswer('NOT_FOUND', 'Route not found'), 404);
  }

  http.Response _page(http.Request request) {
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final limit = int.parse(request.url.queryParameters['limit'] ?? '20');
    final page = pending.skip(offset).take(limit).toList();
    return json200({
      'users': page,
      'total': pending.length,
      'limit': limit,
      'offset': offset,
    });
  }

  http.Response _decide(String id, String status) {
    final index = pending.indexWhere((u) => u['id'] == id);
    if (index < 0) {
      return http.Response(
        errorAnswer(
          'INVALID_STATUS_TRANSITION',
          'Only a pending account can be approved.',
        ),
        409,
      );
    }
    final user = {...pending.removeAt(index), 'status': status};
    return json200({'user': user});
  }

  /// Overrides that make the app's ApiClient talk to this server. Requests
  /// never time out (the delay never completes), so no timer is left running
  /// at the end of a widget test.
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

http.Response json200(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response refusal(int status, String code, [String message = 'Refused.']) =>
    http.Response(errorAnswer(code, message), status);
