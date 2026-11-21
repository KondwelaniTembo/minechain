// TEST ONLY: a stand-in for the GPS zone endpoints (GPS zones plan, T1;
// docs/api.md "GPS zone management (FR-11)") behind package http's
// MockClient. It keeps zones of both statuses and answers the list and the
// four actions with the server's own rules: names unique ignoring letter
// case (inactive zones included), the same name changes nothing, the status
// table, and the NO_ACTIVE_ZONES warning when the last active zone goes.
//
// The shape rules are not copied here (one set, on the server): a test that
// needs a boundary refusal replaces the create answer with
// [boundaryRefusal].
//
// A test can replace any answer, hold every answer back (to see a page while
// a request is in flight), and read every request that was sent. All names,
// ids and licence numbers are fake, in api.md's style; the corners are near
// the campus demo zone.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minechain/core/network/api_client.dart';
import 'package:minechain/core/network/network_providers.dart';
import 'package:minechain/core/network/session_events.dart';

import 'auth_fixtures.dart';

/// Zone [n]'s id.
String zoneId(int n) =>
    '7a1c2d3e-0000-4000-8000-${(100 + n).toString().padLeft(12, '0')}';

/// A small triangle, as api.md's example writes corners.
const List<List<num>> triangle = [
  [-13.45, 25.82],
  [-13.47, 25.86],
  [-13.49, 25.81],
];

/// One zone in the API's zone view.
Map<String, Object?> zoneJson(
  int n, {
  String? name,
  String? id,
  String? licenceNumber = 'DEMO-LML-0001',
  String status = 'active',
  List<List<num>> boundary = triangle,
  String createdAt = '2026-11-10T09:00:00.000Z',
  String? updatedAt,
}) => {
  'id': id ?? zoneId(n),
  'name': name ?? 'Zone $n',
  'licenceNumber': licenceNumber,
  'status': status,
  'boundary': boundary,
  'createdBy': '3f2b6c1e-0000-4000-8000-0000000000ad',
  'createdAt': createdAt,
  'updatedAt': updatedAt ?? createdAt,
};

/// The warning api.md gives when the last active zone is deactivated.
const noActiveZonesMessage =
    'No GPS zone is active now, so every new registration will be flagged as '
    'outside a licensed zone until a zone is created or reactivated.';

/// api.md's ZONE_NAME_TAKEN sentence.
const zoneNameTakenMessage =
    'A GPS zone with this name already exists. Names are compared ignoring '
    'letter case and include inactive zones. Choose another name, or rename '
    'the other zone first.';

typedef ZoneAnswer = FutureOr<http.Response> Function(http.Request request);

class FakeZonesServer {
  FakeZonesServer([List<Map<String, Object?>>? zones])
    : zones =
          zones ??
          [
            zoneJson(1, name: 'Kasempa North'),
            zoneJson(2, name: 'ZCAS Campus (demo)', licenceNumber: null),
            zoneJson(3, name: 'Mumbwa East', status: 'inactive'),
          ];

  /// Every zone, as the server holds them.
  final List<Map<String, Object?>> zones;

  /// Every request received, in order.
  final List<http.Request> received = [];

  /// Replace an answer: 'list', 'create', or an action's path word
  /// ('rename', 'deactivate', 'reactivate'). Absent means the normal
  /// behaviour.
  final Map<String, ZoneAnswer> answers = {};

  /// While set and not completed, every answer waits for it.
  Completer<void>? hold;

  List<http.Request> get lists =>
      received.where((r) => r.method == 'GET').toList();
  List<http.Request> actions(String word) => received
      .where((r) => r.method == 'POST' && r.url.pathSegments.last == word)
      .toList();
  List<http.Request> get creates => received
      .where((r) => r.method == 'POST' && r.url.pathSegments.length == 2)
      .toList();

  Map<String, Object?>? byId(String id) {
    for (final z in zones) {
      if (z['id'] == id) return z;
    }
    return null;
  }

  late final MockClient client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    received.add(request);
    final waiting = hold;
    if (waiting != null) await waiting.future;

    final path = request.url.pathSegments;
    final isZones =
        path.length >= 2 && path[0] == 'admin' && path[1] == 'zones';
    if (!isZones) return refusal(404, 'NOT_FOUND', 'Route not found');

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
    final status = request.url.queryParameters['status'] ?? 'active';
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final limit = int.parse(request.url.queryParameters['limit'] ?? '20');
    // By name, ignoring letter case, as the server lists them.
    final matching = zones.where((z) => z['status'] == status).toList()
      ..sort(
        (a, b) => (a['name'] as String).toLowerCase().compareTo(
          (b['name'] as String).toLowerCase(),
        ),
      );
    return json200({
      'zones': matching.skip(offset).take(limit).toList(),
      'total': matching.length,
      'limit': limit,
      'offset': offset,
    });
  }

  Map<String, Object?> _body(http.Request request) => request.body.isEmpty
      ? const {}
      : (jsonDecode(request.body) as Map).cast<String, Object?>();

  bool _nameTaken(String name, {String? except}) => zones.any(
    (z) =>
        z['id'] != except &&
        (z['name'] as String).toLowerCase() == name.toLowerCase(),
  );

  http.Response _create(http.Request request) {
    final body = _body(request);
    final name = (body['name'] as String).trim();
    if (_nameTaken(name)) {
      return refusal(409, 'ZONE_NAME_TAKEN', zoneNameTakenMessage);
    }
    final boundary = [
      for (final corner in body['boundary'] as List)
        [for (final value in corner as List) value as num],
    ];
    final zone = zoneJson(
      50 + zones.length,
      name: name,
      licenceNumber: body['licenceNumber'] as String?,
      boundary: boundary,
      createdAt: '2026-11-21T09:00:00.000Z',
    );
    zones.add(zone);
    return http.Response(
      jsonEncode({'zone': zone}),
      201,
      headers: {'content-type': 'application/json'},
    );
  }

  http.Response _act(String id, String word, http.Request request) {
    final zone = byId(id);
    if (zone == null) {
      return refusal(404, 'ZONE_NOT_FOUND', 'No GPS zone has this id.');
    }
    final status = zone['status'] as String;
    final body = _body(request);
    http.Response done([Map<String, Object?> extra = const {}]) =>
        json200({'zone': zone, ...extra});

    switch (word) {
      case 'rename':
        final name = (body['name'] as String).trim();
        if (name == zone['name']) return done();
        if (_nameTaken(name, except: id)) {
          return refusal(409, 'ZONE_NAME_TAKEN', zoneNameTakenMessage);
        }
        zone['name'] = name;
        zone['updatedAt'] = '2026-11-21T10:00:00.000Z';
        return done();
      case 'deactivate':
        if (status != 'active') {
          return refusal(
            409,
            'INVALID_STATUS_TRANSITION',
            'Only an active zone can be deactivated. This zone is $status.',
          );
        }
        zone['status'] = 'inactive';
        zone['updatedAt'] = '2026-11-21T10:00:00.000Z';
        final noneLeft = !zones.any((z) => z['status'] == 'active');
        return done({
          'warning': noneLeft
              ? {'code': 'NO_ACTIVE_ZONES', 'message': noActiveZonesMessage}
              : null,
        });
      case 'reactivate':
        if (status != 'inactive') {
          return refusal(
            409,
            'INVALID_STATUS_TRANSITION',
            'Only an inactive zone can be reactivated. This zone is $status.',
          );
        }
        zone['status'] = 'active';
        zone['updatedAt'] = '2026-11-21T10:00:00.000Z';
        return done();
    }
    return refusal(404, 'NOT_FOUND', 'Route not found');
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

/// A VALIDATION_FAILED answer with [details] (`field` → `message`), as the
/// server sends a boundary refusal.
http.Response boundaryRefusal(Map<String, String> details) => http.Response(
  jsonEncode({
    'error': {
      'code': 'VALIDATION_FAILED',
      'message': 'Some fields are missing or invalid.',
      'details': [
        for (final entry in details.entries)
          {'field': entry.key, 'message': entry.value},
      ],
    },
  }),
  400,
  headers: {'content-type': 'application/json'},
);

http.Response json200(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response refusal(int status, String code, [String message = 'Refused.']) =>
    http.Response(errorAnswer(code, message), status);
