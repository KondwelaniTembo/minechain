// TEST ONLY: a stand-in for the two report endpoints (reports plan, T1;
// docs/api.md "Reports (FR-09, FR-13)") behind package http's MockClient.
//
// It answers with the server's rules that the app can meet: the role rules
// (the audit trail is the officer's only), the 366-day period, the known
// consignment and person ids, 20 downloads per 15 minutes (429 with
// Retry-After), and the file itself: a BOM, every field quoted, CRLF, the
// server's filename. A buyer's transactions file holds only their own rows.
// A test can replace any answer, hold every answer back (to see a page
// while a download runs), and read every request sent. All names and ids are
// fake, in api.md's style.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minechain/core/network/api_client.dart';
import 'package:minechain/core/network/network_providers.dart';
import 'package:minechain/core/network/session_events.dart';

import 'auth_fixtures.dart';

const knownConsignmentId = '5c0d7e21-0000-4000-8000-000000000001';
// The actor of fake_alerts_server.dart's alerts.
const knownActorId = '3f2b6c1e-0000-4000-8000-000000000002';

/// api.md's transactions header row (shortened: the app never reads the
/// columns, it only counts records).
const transactionsHeader = '"step_id","qr_code","mineral","step_type"';

/// The bytes of a CSV file as the server writes it: BOM, then each record
/// with CRLF, the last included.
List<int> csvFile(List<String> records) => [
  0xEF,
  0xBB,
  0xBF,
  ...utf8.encode(records.map((r) => '$r\r\n').join()),
];

typedef ReportAnswer = FutureOr<http.Response> Function(http.Request request);

class FakeReportsServer {
  FakeReportsServer({this.role = 'officer', this.rows = 3});

  /// The signed-in account's role, as the server would read it from the
  /// token.
  String role;

  /// How many data rows a report has.
  int rows;

  /// Every request received, in order.
  final List<http.Request> received = [];

  /// Replace an answer: 'transactions' or 'audit-trail'.
  final Map<String, ReportAnswer> answers = {};

  /// While set and not completed, every answer waits for it.
  Completer<void>? hold;

  /// Downloads counted towards the 20 per 15 minutes.
  int counted = 0;

  late final MockClient client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    received.add(request);
    final waiting = hold;
    if (waiting != null) await waiting.future;

    final path = request.url.pathSegments;
    if (path.isEmpty || path[0] != 'reports') {
      return refusal(404, 'NOT_FOUND', 'Route not found');
    }
    // The router guard: miners and transporters are refused before the
    // limiter, and not counted.
    if (!const ['officer', 'buyer', 'admin'].contains(role)) {
      return refusal(
        403,
        'FORBIDDEN',
        'You do not have permission to do this.',
      );
    }
    counted++;
    if (counted > 20) {
      return http.Response(
        errorAnswer(
          'TOO_MANY_REQUESTS',
          'Too many report downloads. Please wait a few minutes and try again.',
        ),
        429,
        headers: const {'retry-after': '600'},
      );
    }
    if (path.length != 2) return refusal(404, 'NOT_FOUND', 'Route not found');
    final replaced = answers[path[1]];
    if (replaced != null) return await replaced(request);
    return switch (path[1]) {
      'transactions' => _transactions(request.url.queryParameters),
      'audit-trail' => _auditTrail(request.url.queryParameters),
      _ => refusal(404, 'NOT_FOUND', 'Route not found'),
    };
  }

  http.Response _transactions(Map<String, String> query) {
    final period = _period(query);
    if (period != null) return period;
    final from = query['from']!;
    final to = query['to']!;
    final mine = role == 'buyer' ? ' (bought by you)' : '';
    return csv([
      transactionsHeader,
      for (var i = 1; i <= rows; i++)
        '"s$i","MC-2026-LSK-000$i$mine","gold","purchase"',
    ], 'minechain-transactions-$from-to-$to.csv');
  }

  http.Response _auditTrail(Map<String, String> query) {
    if (role != 'officer') {
      return refusal(
        403,
        'FORBIDDEN',
        'You do not have permission to do this.',
      );
    }
    final consignment = query['consignmentId'];
    final actor = query['actorId'];
    if ((consignment == null) == (actor == null)) {
      return validation(
        'query',
        'give exactly one of consignmentId and actorId',
      );
    }
    if (consignment != null) {
      if (consignment != knownConsignmentId) {
        return refusal(
          404,
          'CONSIGNMENT_NOT_FOUND',
          'No consignment has this id.',
        );
      }
      return csv([
        '"event_time_utc","event"',
        for (var i = 1; i <= rows; i++)
          '"2026-11-10T07:0$i:00.000Z","step_recorded"',
      ], 'minechain-audit-trail-consignment-$consignment.csv');
    }
    final period = _period(query);
    if (period != null) return period;
    if (actor != knownActorId) {
      return refusal(404, 'USER_NOT_FOUND', 'No user has this id.');
    }
    return csv(
      [
        '"event_time_utc","event"',
        for (var i = 1; i <= rows; i++)
          '"2026-11-10T07:0$i:00.000Z","account_event"',
      ],
      'minechain-audit-trail-user-$actor-${query['from']}-to-${query['to']}.csv',
    );
  }

  /// A refusal if the period is missing or not one the server accepts.
  http.Response? _period(Map<String, String> query) {
    final from = DateTime.tryParse('${query['from']}T00:00:00Z');
    final to = DateTime.tryParse('${query['to']}T00:00:00Z');
    if (from == null || to == null) return validation('from', 'is required');
    final days = to.difference(from).inDays + 1;
    if (days < 1) {
      return validation('to', 'must be the same day as from or later');
    }
    if (days > 366) {
      return validation(
        'to',
        'must be at most 366 days after from, counting both days',
      );
    }
    return null;
  }

  /// Overrides that make the app's ApiClient talk to this server. Requests
  /// never time out (the delay never completes), so no timer is left running
  /// at the end of a widget test.
  ///
  /// [others] answers every request outside /reports (another fake server's
  /// client), for screens that call both, such as the check result and the
  /// alert page.
  List<Override> overrides({http.Client? others}) => [
    apiClientProvider.overrideWith(
      (ref) async => ApiClient(
        client: others == null
            ? client
            : MockClient((request) async {
                if (request.url.pathSegments.firstOrNull == 'reports') {
                  return _handle(request);
                }
                // A fresh copy: MockClient has already finalised this one.
                final copy = http.Request(request.method, request.url)
                  ..followRedirects = request.followRedirects
                  ..headers.addAll(request.headers)
                  ..bodyBytes = request.bodyBytes;
                final streamed = await others.send(copy);
                return http.Response.fromStream(streamed);
              }),
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

/// A 200 CSV answer as the server sends it.
http.Response csv(List<String> records, String filename) => http.Response.bytes(
  csvFile(records),
  200,
  headers: {
    'content-type': 'text/csv; charset=utf-8',
    'content-disposition': 'attachment; filename="$filename"',
    'cache-control': 'no-store',
  },
);

http.Response validation(String field, String message) => http.Response(
  errorAnswer('VALIDATION_FAILED', 'Some fields are missing or invalid.', [
    {'field': field, 'message': message},
  ]),
  400,
);

http.Response refusal(int status, String code, [String message = 'Refused.']) =>
    http.Response(errorAnswer(code, message), status);

/// 422 REPORT_TOO_LARGE, as the server sends it.
http.Response tooLarge(http.Request _) => refusal(
  422,
  'REPORT_TOO_LARGE',
  'This report has more than 10,000 rows. Choose a shorter date range or add a filter.',
);
