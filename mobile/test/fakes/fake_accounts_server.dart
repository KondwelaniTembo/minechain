// TEST ONLY: a stand-in for the "Accounts" endpoints (admin accounts plan,
// T1; docs/api.md "Admin account management") behind package http's
// MockClient. It keeps accounts of every status and answers the list and the
// eight actions with the server's own rules: the status table, "not your own
// account", the last active administrator, no device key to reset, a taken
// username.
//
// A separate file from fake_admin_server.dart, so the "Account requests"
// tests keep the fake they were written against.
//
// A test can replace any action's answer, hold every answer back (to see a
// page while a request is in flight), and read every request that was sent.
// All names, ids and codes are fake, in api.md's style.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minechain/core/network/api_client.dart';
import 'package:minechain/core/network/network_providers.dart';
import 'package:minechain/core/network/session_events.dart';

import 'auth_fixtures.dart';

/// The signed-in administrator's own id in the tests (userOf in
/// fake_controllers.dart reads userJson's default id).
const ownId = '3f2b6c1e-0000-4000-8000-000000000001';

/// Account [n]'s id.
String accountId(int n) =>
    '3f2b6c1e-0000-4000-8000-${(200 + n).toString().padLeft(12, '0')}';

/// A fingerprint like the server's: 64 hex characters.
const fakeFingerprint =
    '50a03528c1d2e3f405162738495a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6';

/// One account in the API's admin view. [n] makes the id, username and name
/// unique.
Map<String, Object?> accountJson(
  int n, {
  String role = 'miner',
  String status = 'active',
  String? fullName,
  String? username,
  String? id,
  String? licenceNumber = 'ZM-ASM-0042',
  String? statusReason,
  String? fingerprint,
  String? approvedAt = '2026-11-06T10:15:00.000Z',
  String? activationExpiresAt,
  String createdAt = '2026-11-05T09:00:00.000Z',
}) => {
  'id': id ?? accountId(n),
  'username': username ?? 'demo_user_$n',
  'fullName': fullName ?? 'Demo Person $n',
  'licenceNumber': licenceNumber,
  'role': role,
  'status': status,
  'statusReason': statusReason,
  'approvedBy': approvedAt == null
      ? null
      : '3f2b6c1e-0000-4000-8000-0000000000ad',
  'approvedAt': approvedAt,
  'createdAt': createdAt,
  'updatedAt': createdAt,
  'publicKeyFingerprint': fingerprint,
  'activationExpiresAt': activationExpiresAt,
};

/// The signed-in administrator's own account, as the list shows it.
Map<String, Object?> ownAccountJson() => accountJson(
  0,
  id: ownId,
  username: 'mutale_banda',
  fullName: 'Mutale Banda',
  role: 'admin',
  licenceNumber: null,
  approvedAt: null,
);

typedef AccountAnswer = FutureOr<http.Response> Function(http.Request request);

class FakeAccountsServer {
  FakeAccountsServer([List<Map<String, Object?>>? accounts])
    : accounts =
          accounts ??
          [
            ownAccountJson(),
            accountJson(1, fingerprint: fakeFingerprint),
            accountJson(2, role: 'transporter'),
            accountJson(3, role: 'officer', licenceNumber: null),
          ];

  /// Every account, oldest first, as the server holds them.
  final List<Map<String, Object?>> accounts;

  /// Every request received, in order.
  final List<http.Request> received = [];

  /// Replace an answer: 'list', 'create', or an action's path word
  /// ('rename', 'suspend', 'reactivate', 'reset-key', 'activation-code',
  /// 'delete'). Absent means the normal behaviour.
  final Map<String, AccountAnswer> answers = {};

  /// While set and not completed, every answer waits for it.
  Completer<void>? hold;

  /// The codes handed out, in order, so a test can see a new one each time.
  int codesIssued = 0;

  List<http.Request> get lists =>
      received.where((r) => r.method == 'GET').toList();
  List<http.Request> actions(String word) => received
      .where((r) => r.method == 'POST' && r.url.pathSegments.last == word)
      .toList();
  List<http.Request> get creates => received
      .where((r) => r.method == 'POST' && r.url.pathSegments.length == 2)
      .toList();

  Map<String, Object?>? byId(String id) {
    for (final a in accounts) {
      if (a['id'] == id) return a;
    }
    return null;
  }

  late final MockClient client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    received.add(request);
    final waiting = hold;
    if (waiting != null) await waiting.future;

    final path = request.url.pathSegments;
    final isUsers =
        path.length >= 2 && path[0] == 'admin' && path[1] == 'users';
    if (!isUsers) return refusal(404, 'NOT_FOUND', 'Route not found');

    if (path.length == 2) {
      if (request.method == 'GET') {
        return await (answers['list']?.call(request) ?? _page(request));
      }
      if (request.method == 'POST') {
        return await (answers['create']?.call(request) ?? _create(request));
      }
    }
    if (request.method == 'POST' && path.length == 4) {
      final word = path[3];
      final replaced = answers[word];
      if (replaced != null) return await replaced(request);
      return _act(path[2], word, request);
    }
    return refusal(404, 'NOT_FOUND', 'Route not found');
  }

  http.Response _page(http.Request request) {
    final status = request.url.queryParameters['status'] ?? 'pending';
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final limit = int.parse(request.url.queryParameters['limit'] ?? '20');
    final matching = accounts.where((a) => a['status'] == status).toList();
    return json200({
      'users': matching.skip(offset).take(limit).toList(),
      'total': matching.length,
      'limit': limit,
      'offset': offset,
    });
  }

  Map<String, Object?> _body(http.Request request) => request.body.isEmpty
      ? const {}
      : (jsonDecode(request.body) as Map).cast<String, Object?>();

  http.Response _create(http.Request request) {
    final body = _body(request);
    final username = (body['username'] as String).trim();
    final role = body['role'];
    if (role != 'officer' && role != 'admin') {
      return refusal(400, 'VALIDATION_FAILED', 'Some fields are missing.');
    }
    final taken = accounts.any(
      (a) => (a['username'] as String).toLowerCase() == username.toLowerCase(),
    );
    if (taken) {
      return refusal(
        409,
        'USERNAME_TAKEN',
        'That username is already taken. Please choose another.',
      );
    }
    final n = 50 + accounts.length;
    final account = accountJson(
      n,
      username: username,
      fullName: (body['fullName'] as String).trim(),
      role: role as String,
      status: 'invited',
      licenceNumber: null,
      approvedAt: null,
      createdAt: '2026-11-21T09:00:00.000Z',
      activationExpiresAt: '2026-11-24T09:00:00.000Z',
    );
    accounts.add(account);
    return http.Response(
      jsonEncode({'user': account, 'activation': _newCode()}),
      201,
      headers: {'content-type': 'application/json'},
    );
  }

  Map<String, String> _newCode() {
    codesIssued++;
    return {
      'code': codesIssued == 1 ? '7KQ4-M2XD-9TNE' : '9TNE-7KQ4-M2X$codesIssued',
      'expiresAt': '2026-11-24T09:00:00.000Z',
    };
  }

  http.Response _act(String id, String word, http.Request request) {
    final account = byId(id);
    if (account == null) {
      return refusal(404, 'USER_NOT_FOUND', 'No user has this id.');
    }
    final status = account['status'] as String;
    final body = _body(request);

    http.Response wrong(String message) =>
        refusal(409, 'INVALID_STATUS_TRANSITION', message);
    http.Response done() => json200({'user': account});

    switch (word) {
      case 'rename':
        if (status == 'rejected' || status == 'deleted') {
          return wrong('A $status account cannot be changed.');
        }
        account['fullName'] = (body['fullName'] as String).trim();
        return done();
      case 'suspend':
        if (id == ownId) {
          return refusal(
            403,
            'CANNOT_SUSPEND_SELF',
            'You cannot suspend your own account.',
          );
        }
        if (status != 'active') {
          return wrong(
            'Only an active account can be suspended. This account is '
            '$status.',
          );
        }
        if (_lastActiveAdmin(account)) {
          return refusal(
            409,
            'LAST_ACTIVE_ADMIN',
            'At least one other active administrator must remain, so this '
                'account cannot be suspended.',
          );
        }
        account['status'] = 'suspended';
        account['statusReason'] = (body['reason'] as String).trim();
        return done();
      case 'reactivate':
        if (status != 'suspended') {
          return wrong(
            'Only a suspended account can be reactivated. This account is '
            '$status.',
          );
        }
        account['status'] = 'active';
        account['statusReason'] = null;
        return done();
      case 'reset-key':
        if (status != 'suspended') {
          return wrong(
            'Only a suspended account can have its device key reset. This '
            'account is $status.',
          );
        }
        if (account['publicKeyFingerprint'] == null) {
          return refusal(
            409,
            'NO_PUBLIC_KEY',
            'This account has no device key to reset.',
          );
        }
        account['publicKeyFingerprint'] = null;
        return done();
      case 'activation-code':
        if (status != 'invited') {
          return wrong(
            'Only an invited account can get a new activation code. This '
            'account is $status.',
          );
        }
        account['activationExpiresAt'] = '2026-11-24T09:00:00.000Z';
        return json200({'user': account, 'activation': _newCode()});
      case 'delete':
        if (id == ownId) {
          return refusal(
            403,
            'CANNOT_DELETE_SELF',
            'You cannot delete your own account.',
          );
        }
        if (status == 'deleted') {
          return wrong('This account has already been deleted.');
        }
        if (!const {'active', 'suspended', 'invited'}.contains(status)) {
          return wrong(
            'Only an active, suspended or invited account can be deleted. '
            'This account is $status.',
          );
        }
        if (_lastActiveAdmin(account)) {
          return refusal(
            409,
            'LAST_ACTIVE_ADMIN',
            'At least one other active administrator must remain, so this '
                'account cannot be deleted.',
          );
        }
        account['status'] = 'deleted';
        account['statusReason'] = (body['reason'] as String).trim();
        account['publicKeyFingerprint'] = null;
        account['activationExpiresAt'] = null;
        return done();
    }
    return refusal(404, 'NOT_FOUND', 'Route not found');
  }

  /// True when [account] is an active administrator and no other is.
  bool _lastActiveAdmin(Map<String, Object?> account) {
    if (account['role'] != 'admin' || account['status'] != 'active') {
      return false;
    }
    return !accounts.any(
      (a) =>
          a['id'] != account['id'] &&
          a['role'] == 'admin' &&
          a['status'] == 'active',
    );
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
