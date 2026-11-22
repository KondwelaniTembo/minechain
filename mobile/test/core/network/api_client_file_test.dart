// ApiClient.getFile (reports plan, T1): a file answer instead of JSON, with
// the same refusals and session events as every other call.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/network/api_client.dart';
import 'package:minechain/core/network/session_events.dart';

const token = 'FAKE-TOKEN-do-not-leak';

/// api.md's header row, with the BOM the server puts first.
final csvBytes = [
  0xEF,
  0xBB,
  0xBF,
  ...utf8.encode('"step_id","qr_code"\r\n"s1","MC-1"\r\n'),
];

ApiClient apiOn(MockClient client, {SessionEvents? events}) => ApiClient(
  client: client,
  baseUri: Uri.parse('https://api.example.test'),
  sessionEvents: events ?? SessionEvents(),
  delay: (_) => Completer<void>().future,
);

MockClient answering(
  int status,
  List<int> body, {
  Map<String, String> headers = const {},
  void Function(http.Request)? seen,
}) => MockClient((request) async {
  seen?.call(request);
  return http.Response.bytes(body, status, headers: headers);
});

const csvHeaders = {
  'content-type': 'text/csv; charset=utf-8',
  'content-disposition': 'attachment; filename="minechain-transactions-2026-11-01-to-2026-11-30.csv"',
};

Future<AppFailure> failureOf(Future<Object?> Function() action) async {
  try {
    await action();
  } on AppFailure catch (f) {
    return f;
  }
  fail('expected an AppFailure');
}

void main() {
  Future<DownloadedFile> download(MockClient client) => apiOn(client).getFile(
    const ['reports', 'transactions'],
    mediaType: 'text/csv',
    token: token,
  );

  test('a CSV answer gives its exact bytes and the filename', () async {
    final file = await download(answering(200, csvBytes, headers: csvHeaders));
    expect(file.bytes, csvBytes); // the BOM included
    expect(
      file.filename,
      'minechain-transactions-2026-11-01-to-2026-11-30.csv',
    );
  });

  test('it asks for the media type, with the token in the header', () async {
    late http.Request sent;
    await apiOn(
      answering(200, csvBytes, headers: csvHeaders, seen: (r) => sent = r),
    ).getFile(
      const ['reports', 'audit-trail'],
      mediaType: 'text/csv',
      query: const {'consignmentId': 'abc'},
      token: token,
    );
    expect(sent.method, 'GET');
    expect(sent.headers['accept'], 'text/csv');
    expect(sent.headers['authorization'], 'Bearer $token');
    expect(
      sent.url.toString(),
      'https://api.example.test/reports/audit-trail?consignmentId=abc',
    );
  });

  test('the media type is compared without its parameters or case', () async {
    final file = await download(
      answering(200, csvBytes, headers: {'content-type': 'Text/CSV'}),
    );
    expect(file.bytes, csvBytes);
    expect(file.filename, isNull);
  });

  group('a 200 that is not the file is a BadResponse', () {
    final cases = {
      'JSON': {'content-type': 'application/json'},
      'an HTML page': {'content-type': 'text/html'},
      'no content type': <String, String>{},
    };
    cases.forEach((name, headers) {
      test(name, () async {
        final failure = await failureOf(
          () => download(answering(200, csvBytes, headers: headers)),
        );
        expect(failure, isA<BadResponse>());
      });
    });

    test('an empty body', () async {
      final failure = await failureOf(
        () => download(answering(200, const [], headers: csvHeaders)),
      );
      expect(failure, isA<BadResponse>());
    });
  });

  group('only the API\'s own filename form is kept', () {
    const refused = [
      'attachment; filename="../minechain.csv"',
      'attachment; filename="reports/x.csv"',
      'attachment; filename="a\\\\b.csv"',
      'attachment; filename="MineChain.csv"',
      'attachment; filename=".hidden.csv"',
      'attachment; filename="a..csv"',
      'attachment; filename="x.csv"; size=3',
      'inline; filename="x.csv"',
      'attachment; filename=x.csv',
      'attachment; filename=""',
    ];
    for (final header in refused) {
      test(header, () async {
        final file = await download(
          answering(
            200,
            csvBytes,
            headers: {
              'content-type': 'text/csv',
              'content-disposition': header,
            },
          ),
        );
        expect(file.filename, isNull);
      });
    }

    test('a name over 120 characters', () async {
      final name = '${'a' * 117}.csv';
      final file = await download(
        answering(
          200,
          csvBytes,
          headers: {
            'content-type': 'text/csv',
            'content-disposition': 'attachment; filename="$name"',
          },
        ),
      );
      expect(file.filename, isNull);
    });
  });

  test('a refusal is the JSON error format, as for any call', () async {
    final failure = await failureOf(
      () => download(
        answering(
          422,
          utf8.encode(
            jsonEncode({
              'error': {
                'code': ApiCodes.reportTooLarge,
                'message': 'This report has more than 10,000 rows.',
              },
            }),
          ),
          headers: const {'retry-after': '30'},
        ),
      ),
    );
    expect(
      failure,
      isA<ServerRefused>()
          .having((f) => f.status, 'status', 422)
          .having((f) => f.code, 'code', ApiCodes.reportTooLarge)
          .having(
            (f) => f.retryAfter,
            'retryAfter',
            const Duration(seconds: 30),
          ),
    );
  });

  test('an expired token on a download ends the session', () async {
    final events = SessionEvents();
    final seen = <String>[];
    final subscription = events.refusals.listen(seen.add);
    await failureOf(
      () => apiOn(
        answering(
          401,
          utf8.encode(
            jsonEncode({
              'error': {'code': ApiCodes.tokenExpired, 'message': 'm'},
            }),
          ),
        ),
        events: events,
      ).getFile(const ['reports', 'x'], mediaType: 'text/csv', token: token),
    );
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    expect(seen, [ApiCodes.tokenExpired]);
  });

  test('the file\'s toString has no bytes or name', () async {
    final file = await download(answering(200, csvBytes, headers: csvHeaders));
    expect(file.toString(), 'DownloadedFile(${csvBytes.length} bytes)');
  });

  test('JSON calls still ask for JSON', () async {
    late http.Request sent;
    await apiOn(
      MockClient((r) async {
        sent = r;
        return http.Response('{}', 200);
      }),
    ).get(const ['health']);
    expect(sent.headers['accept'], 'application/json');
  });
}
