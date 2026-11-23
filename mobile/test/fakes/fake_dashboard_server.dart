// TEST ONLY: a stand-in for GET /dashboard (dashboard plan, T3; docs/api.md
// "GET /dashboard") behind package http's MockClient.
//
// By default it answers each request with a summary for the days the request
// asks for ([dashboardJson], with every day listed), so the period chips work
// as on the real server. A test changes the counts with [dashboardJson]'s
// named values through [build], replaces the answer with [answer], holds
// every answer back with [hold], and reads every request in [received].
// Every id is fake, in api.md's style.

import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minechain/core/network/api_client.dart';
import 'package:minechain/core/network/network_providers.dart';
import 'package:minechain/core/network/session_events.dart';

import 'fake_admin_server.dart' show json200, refusal;

/// Zone [n]'s id.
String dashboardZoneId(int n) =>
    '7a1c2d3e-0000-4000-8000-${n.toString().padLeft(12, '0')}';

/// Every UTC day from [from] to [to], both included, as YYYY-MM-DD.
List<String> daysBetween(String from, String to) {
  final first = DateTime.parse('${from}T00:00:00Z');
  final last = DateTime.parse('${to}T00:00:00Z');
  return [
    for (
      var day = first;
      !day.isAfter(last);
      day = DateTime.utc(day.year, day.month, day.day + 1)
    )
      day.toIso8601String().substring(0, 10),
  ];
}

/// One `byDay` row.
Map<String, Object?> dayJson(
  String day, {
  int registration = 0,
  int handoff = 0,
  int purchase = 0,
}) => {
  'day': day,
  'registration': registration,
  'handoff': handoff,
  'purchase': purchase,
};

/// A whole answer for [from]..[to]. [steps] puts counts on chosen days
/// (`{day: (registration, handoff, purchase)}`); `steps` in the answer is
/// their sum. Everything else can be changed.
Map<String, Object?> dashboardJson({
  String from = '2026-11-17',
  String to = '2026-11-23',
  String? mineral,
  int openAlerts = 8,
  Map<String, int> consignments = const {
    'registered': 4,
    'in_transit': 3,
    'purchased': 2,
  },
  Map<String, (int, int, int)> steps = const {
    '2026-11-17': (2, 0, 0),
    '2026-11-18': (1, 2, 0),
    '2026-11-20': (3, 3, 2),
    '2026-11-23': (3, 2, 3),
  },
  String registeredWeightMg = '18500000',
  List<Map<String, Object?>> byMineral = const [
    {'mineral': 'gold', 'steps': 12, 'registeredWeightMg': '6500000'},
    {'mineral': 'copper', 'steps': 9, 'registeredWeightMg': '12000000'},
  ],
  List<Map<String, Object?>>? byZone,
  int outsideZones = 6,
  int anomaliesTotal = 5,
  int anomaliesOpen = 3,
  Map<String, int> byType = const {
    'duplicate_consignment': 1,
    'quantity_discrepancy': 2,
    'gps_zone': 1,
    'invalid_signature': 0,
    'handoff_order': 1,
    'record_tampered': 0,
  },
  Map<String, int> bySeverity = const {'low': 0, 'medium': 3, 'high': 2},
}) {
  final days = daysBetween(from, to);
  var registration = 0, handoff = 0, purchase = 0;
  final byDay = [
    for (final day in days)
      () {
        final (r, h, p) = steps[day] ?? (0, 0, 0);
        registration += r;
        handoff += h;
        purchase += p;
        return dayJson(day, registration: r, handoff: h, purchase: p);
      }(),
  ];
  return {
    'period': {'from': from, 'to': to, 'days': days.length},
    'mineral': mineral,
    'now': {'openAlerts': openAlerts, 'consignments': consignments},
    'steps': {
      'total': registration + handoff + purchase,
      'registration': registration,
      'handoff': handoff,
      'purchase': purchase,
    },
    'registeredWeightMg': registeredWeightMg,
    'byDay': byDay,
    'byMineral': byMineral,
    'byZone':
        byZone ??
        [
          {
            'zoneId': dashboardZoneId(1),
            'zoneName': 'ZCAS Campus (demo)',
            'active': true,
            'steps': 15,
          },
        ],
    'outsideZones': outsideZones,
    'anomalies': {
      'total': anomaliesTotal,
      'open': anomaliesOpen,
      'byType': byType,
      'bySeverity': bySeverity,
    },
  };
}

/// A period with nothing in it.
Map<String, Object?> emptyDashboardJson({
  String from = '2026-11-17',
  String to = '2026-11-23',
  String? mineral,
}) => dashboardJson(
  from: from,
  to: to,
  mineral: mineral,
  openAlerts: 0,
  consignments: const {'registered': 0, 'in_transit': 0, 'purchased': 0},
  steps: const {},
  registeredWeightMg: '0',
  byMineral: const [],
  byZone: const [],
  outsideZones: 0,
  anomaliesTotal: 0,
  anomaliesOpen: 0,
  byType: const {
    'duplicate_consignment': 0,
    'quantity_discrepancy': 0,
    'gps_zone': 0,
    'invalid_signature': 0,
    'handoff_order': 0,
    'record_tampered': 0,
  },
  bySeverity: const {'low': 0, 'medium': 0, 'high': 0},
);

typedef DashboardAnswer = FutureOr<http.Response> Function(
  http.Request request,
);

/// Builds the answer for a request's from, to and mineral.
typedef DashboardBuilder = Map<String, Object?> Function(
  String from,
  String to,
  String? mineral,
);

class FakeDashboardServer {
  FakeDashboardServer({DashboardBuilder? build})
    : build =
          build ??
          ((from, to, mineral) =>
              dashboardJson(from: from, to: to, mineral: mineral));

  /// What GET /dashboard answers, for the days and mineral asked for.
  DashboardBuilder build;

  /// Replaces the answer when set (a refusal, a malformed body).
  DashboardAnswer? answer;

  /// While set, every answer waits for it.
  Completer<void>? hold;

  final List<http.Request> received = [];

  late final MockClient client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    received.add(request);
    final waiting = hold;
    if (waiting != null) await waiting.future;

    final path = request.url.pathSegments;
    if (request.method != 'GET' || path.length != 1 || path[0] != 'dashboard') {
      return refusal(404, 'NOT_FOUND', 'Route not found');
    }
    final replaced = answer;
    if (replaced != null) return await replaced(request);
    final query = request.url.queryParameters;
    final from = query['from'];
    final to = query['to'];
    if (from == null || to == null) {
      return refusal(
        400,
        'VALIDATION_FAILED',
        'Some fields are missing or invalid.',
      );
    }
    return json200(build(from, to, query['mineral']));
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
