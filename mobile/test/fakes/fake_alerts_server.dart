// TEST ONLY: a stand-in for the four alert endpoints (docs/api.md, "Alerts
// (FR-08)"), behind package http's MockClient. It keeps every alert, open
// and closed, answers the list per status and the detail with its
// otherAlerts, and closes an alert on review or dismiss as the real server
// would: 409 INVALID_STATUS_TRANSITION when it is already closed, 409
// STEP_CANNOT_BE_CLEARED when a handoff_order alert is dismissed, and `held`
// worked out again from the open alerts left on the consignment.
//
// A test can replace any answer, hold every answer back (to see a screen
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
import 'fake_admin_server.dart' show Answer, json200;

String alertId(int n) =>
    '7a3e9b10-0000-4000-8000-${(100 + n).toString().padLeft(12, '0')}';
String stepIdFor(int n) =>
    '9d4e5f60-0000-4000-8000-${(100 + n).toString().padLeft(12, '0')}';
const consignmentA = '5c0d7e21-0000-4000-8000-000000000001';
const officerId = '3f2b6c1e-0000-4000-8000-000000000009';

/// MC-2026-LSK-0008's handoff: 1.6 kg against a 2 kg registration.
Map<String, Object?> quantityDetails({
  String weightMg = '1600000',
  String registrationMg = '2000000',
  String differenceMg = '-400000',
}) => {
  'weightMg': weightMg,
  'thresholdPercent': 10,
  'failedBaselines': ['registration'],
  'registration': {
    'stepId': stepIdFor(0),
    'weightMg': registrationMg,
    'differenceMg': differenceMg,
    'exceeded': true,
  },
};

/// One alert in the API's alert view. [n] makes the ids unique and the
/// createdAt a minute apart (oldest first by n).
Map<String, Object?> alertJson(
  int n, {
  String type = 'quantity_discrepancy',
  String severity = 'medium',
  String status = 'open',
  Map<String, Object?>? details,
  String stepType = 'handoff',
  String reviewStatus = 'flagged',
  String consignmentId = consignmentA,
  String qrCode = 'MC-2026-LSK-0008',
  String mineral = 'copper',
  String stage = 'registered',
  bool held = true,
  String username = 'patsani',
  String role = 'transporter',
  Map<String, Object?>? review,
  List<Map<String, Object?>>? otherAlerts,
}) => {
  'id': alertId(n),
  'type': type,
  'severity': severity,
  'status': status,
  'details': details ?? quantityDetails(),
  'createdAt': '2026-11-20T12:${(n % 60).toString().padLeft(2, '0')}:01.120Z',
  'step': {
    'id': stepIdFor(n),
    'type': stepType,
    'reviewStatus': reviewStatus,
    'anchorStatus': 'pending',
    'capturedAt': '2026-11-20T11:50:00.000Z',
    'receivedAt': '2026-11-20T12:00:01.118Z',
  },
  'consignment': {
    'id': consignmentId,
    'qrCode': qrCode,
    'mineral': mineral,
    'stage': stage,
    'held': held,
  },
  'actor': {
    'id': '3f2b6c1e-0000-4000-8000-000000000002',
    'username': username,
    'role': role,
  },
  'review':
      review ??
      (status == 'open'
          ? null
          : {
              'by': {'id': officerId, 'username': 'officer_chanda'},
              'notes': 'Weighed again at the depot.',
              'at': '2026-11-20T13:00:00.000Z',
            }),
  'otherAlerts': ?otherAlerts,
};

class FakeAlertsServer {
  FakeAlertsServer([List<Map<String, Object?>>? alerts])
    : alerts = alerts ?? [alertJson(1)];

  /// Every alert, oldest first, as the server holds them.
  final List<Map<String, Object?>> alerts;

  /// Every request received, in order.
  final List<http.Request> received = [];

  /// Replace an endpoint's answer. Null means the normal behaviour.
  Answer? listAnswer;
  Answer? detailAnswer;
  Answer? reviewAnswer;
  Answer? dismissAnswer;

  /// While set and not completed, every answer waits for it.
  Completer<void>? hold;

  List<http.Request> get lists => received
      .where((r) => r.method == 'GET' && r.url.pathSegments.length == 1)
      .toList();
  List<http.Request> get details => received
      .where((r) => r.method == 'GET' && r.url.pathSegments.length == 2)
      .toList();
  List<http.Request> get reviews =>
      received.where((r) => r.url.path.endsWith('/review')).toList();
  List<http.Request> get dismissals =>
      received.where((r) => r.url.path.endsWith('/dismiss')).toList();

  late final MockClient client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    received.add(request);
    final waiting = hold;
    if (waiting != null) await waiting.future;

    final path = request.url.pathSegments;
    if (path.isEmpty || path[0] != 'alerts') return _routeNotFound();
    if (request.method == 'GET' && path.length == 1) {
      return await (listAnswer?.call(request) ?? _page(request));
    }
    if (request.method == 'GET' && path.length == 2) {
      return await (detailAnswer?.call(request) ?? _detail(path[1]));
    }
    if (request.method == 'POST' && path.length == 3) {
      switch (path[2]) {
        case 'review':
          return await (reviewAnswer?.call(request) ??
              _decide(path[1], 'reviewed', request));
        case 'dismiss':
          return await (dismissAnswer?.call(request) ??
              _decide(path[1], 'dismissed', request));
      }
    }
    return _routeNotFound();
  }

  http.Response _routeNotFound() =>
      http.Response(errorAnswer('NOT_FOUND', 'Route not found'), 404);

  http.Response _alertNotFound() => http.Response(
    errorAnswer('ALERT_NOT_FOUND', 'No alert has this id.'),
    404,
  );

  http.Response _page(http.Request request) {
    final status = request.url.queryParameters['status'] ?? 'open';
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final limit = int.parse(request.url.queryParameters['limit'] ?? '20');
    final matching = alerts.where((a) => a['status'] == status).toList();
    // Open: oldest first. Closed: newest decision first (all fakes are
    // decided at the same time, so the newest alert first).
    final ordered = status == 'open' ? matching : matching.reversed.toList();
    return json200({
      'alerts': [
        for (final a in ordered.skip(offset).take(limit)) _withHeld(a),
      ],
      'total': ordered.length,
      'limit': limit,
      'offset': offset,
    });
  }

  http.Response _detail(String id) {
    final alert = _find(id);
    if (alert == null) return _alertNotFound();
    final consignmentId = (alert['consignment'] as Map)['id'];
    return json200({
      'alert': {
        ..._withHeld(alert),
        'otherAlerts': [
          for (final other in alerts)
            if (other['id'] != id &&
                (other['consignment'] as Map)['id'] == consignmentId)
              {
                'id': other['id'],
                'type': other['type'],
                'severity': other['severity'],
                'status': other['status'],
                'stepId': (other['step'] as Map)['id'],
                'createdAt': other['createdAt'],
              },
        ],
      },
    });
  }

  http.Response _decide(String id, String status, http.Request request) {
    final index = alerts.indexWhere((a) => a['id'] == id);
    if (index < 0) return _alertNotFound();
    final alert = alerts[index];
    if (alert['status'] != 'open') {
      final decision = status == 'reviewed' ? 'reviewed' : 'dismissed';
      return http.Response(
        errorAnswer(
          'INVALID_STATUS_TRANSITION',
          'Only an open alert can be $decision. This alert is '
              '${alert['status']}.',
        ),
        409,
      );
    }
    if (status == 'dismissed' && alert['type'] == 'handoff_order') {
      return http.Response(
        errorAnswer(
          'STEP_CANNOT_BE_CLEARED',
          'This step cannot be cleared: it was recorded after the '
              'consignment was purchased, and nothing can follow a purchase '
              'on the blockchain. Confirm the problem instead.',
        ),
        409,
      );
    }

    final notes = (jsonDecode(request.body) as Map)['notes'] as String;
    final step = alert['step'] as Map<String, Object?>;
    final consignment = alert['consignment'] as Map<String, Object?>;
    final stepStatus = status == 'reviewed' ? 'rejected' : 'cleared';
    var stage = consignment['stage'] as String;
    if (status == 'dismissed') {
      if (step['type'] == 'handoff' && stage == 'registered') {
        stage = 'in_transit';
      } else if (step['type'] == 'purchase' && stage == 'in_transit') {
        stage = 'purchased';
      }
    }
    final closed = {
      ...alert,
      'status': status,
      'step': {...step, 'reviewStatus': stepStatus},
      'consignment': {...consignment, 'stage': stage},
      'review': {
        'by': {'id': officerId, 'username': 'officer_chanda'},
        'notes': notes,
        'at': '2026-11-20T13:00:00.000Z',
      },
    };
    alerts[index] = closed;
    final view = _withHeld(closed);
    return json200({
      'alert': view,
      'step': {'id': step['id'], 'reviewStatus': stepStatus},
      'consignment': {
        'id': consignment['id'],
        'stage': stage,
        'held': (view['consignment'] as Map)['held'],
      },
    });
  }

  Map<String, Object?>? _find(String id) {
    for (final alert in alerts) {
      if (alert['id'] == id) return alert;
    }
    return null;
  }

  /// The alert with `held` worked out now, as the server does on every read.
  Map<String, Object?> _withHeld(Map<String, Object?> alert) {
    final consignment = alert['consignment'] as Map<String, Object?>;
    final held = alerts.any(
      (a) =>
          a['status'] == 'open' &&
          (a['consignment'] as Map)['id'] == consignment['id'],
    );
    return {
      ...alert,
      'consignment': {...consignment, 'held': held},
    };
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
