// ApiClient against a pretend server: MockClient answers each request with
// whatever the test says, so there is no network and no waiting.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/network/api_client.dart';
import 'package:minechain/core/network/session_events.dart';

final base = Uri.parse('https://api.example.test');
const token = 'FAKE-TOKEN-do-not-leak';

/// A delay that never ends: requests never time out unless a test says so.
Future<void> never(Duration _) => Completer<void>().future;

ApiClient apiWith(
  http.Client client, {
  SessionEvents? events,
  Delay delay = never,
}) => ApiClient(
  client: client,
  baseUri: base,
  sessionEvents: events ?? SessionEvents(),
  delay: delay,
);

/// A server that always gives [status] and [body].
MockClient answering(int status, String body, {void Function(http.Request)? seen}) {
  return MockClient((request) async {
    seen?.call(request);
    return http.Response(body, status);
  });
}

String envelope(String code, String message, [List<Object>? details]) =>
    jsonEncode({
      'error': {
        'code': code,
        'message': message,
        'details': ?details,
      },
    });

/// Runs [action] and returns the AppFailure it throws (fails the test if it
/// does not throw one).
Future<AppFailure> failureOf(Future<Object?> Function() action) async {
  try {
    await action();
  } on AppFailure catch (f) {
    return f;
  }
  fail('expected an AppFailure');
}

void main() {
  group('successful answers', () {
    test('200 with JSON gives the decoded value', () async {
      final api = apiWith(answering(200, '{"status":"ok"}'));
      expect(await api.get(['health']), {'status': 'ok'});
    });

    test('an empty 2xx body is null when no body is expected', () async {
      final api = apiWith(answering(204, ''));
      expect(await api.post(['x'], expectBody: false), isNull);
    });

    test('an empty 2xx body is a BadResponse when a body is expected', () async {
      final failure = await failureOf(() => apiWith(answering(200, '')).get(['x']));
      expect(failure, isA<BadResponse>().having((f) => f.status, 'status', 200));
    });

    test('200 with invalid JSON is a BadResponse', () async {
      final failure = await failureOf(
        () => apiWith(answering(200, '<html>hello</html>')).get(['x']),
      );
      expect(failure, isA<BadResponse>().having((f) => f.status, 'status', 200));
    });
  });

  group('refusals', () {
    test('the error format becomes ServerRefused, with details', () async {
      final api = apiWith(
        answering(
          400,
          envelope('WEAK_PASSWORD', 'Choose a stronger password.', [
            {
              'field': 'password',
              'code': 'PASSWORD_TOO_SHORT',
              'message': 'Use at least 12 characters.',
            },
            {'field': 'body', 'message': 'is not allowed'},
            'not a detail', // ignored, not fatal
          ]),
        ),
      );

      final failure = await failureOf(() => api.post(['auth', 'register'], body: {}));

      expect(failure, isA<ServerRefused>());
      final refused = failure as ServerRefused;
      expect(refused.status, 400);
      expect(refused.code, 'WEAK_PASSWORD');
      expect(refused.serverMessage, 'Choose a stronger password.');
      expect(refused.details, hasLength(2));
      expect(refused.details[0].field, 'password');
      expect(refused.details[0].code, 'PASSWORD_TOO_SHORT');
      expect(refused.details[0].message, 'Use at least 12 characters.');
      expect(refused.details[1].field, 'body');
      expect(refused.details[1].code, isNull);
    });

    test('an HTML 502 from the proxy is a BadResponse', () async {
      final failure = await failureOf(
        () => apiWith(answering(502, '<html>Bad gateway</html>')).get(['x']),
      );
      expect(failure, isA<BadResponse>().having((f) => f.status, 'status', 502));
    });

    test('JSON that is not the error format is a BadResponse', () async {
      // /health's own 503 body, for example.
      final failure = await failureOf(
        () => apiWith(answering(503, '{"status":"error","database":"down"}'))
            .get(['health']),
      );
      expect(failure, isA<BadResponse>().having((f) => f.status, 'status', 503));
    });

    test('a redirect is not followed, and is a BadResponse', () async {
      http.Request? sent;
      final failure = await failureOf(
        () => apiWith(answering(302, '', seen: (r) => sent = r)).get(['x']),
      );
      expect(sent!.followRedirects, isFalse);
      expect(failure, isA<BadResponse>().having((f) => f.status, 'status', 302));
    });
  });

  group('what is sent', () {
    test('the token goes only in the Authorization header', () async {
      late http.Request sent;
      final api = apiWith(answering(200, '{}', seen: (r) => sent = r));

      await api.post(['auth', 'me', 'password'], body: {'a': 'b'}, token: token);

      expect(sent.headers['authorization'], 'Bearer $token');
      expect(sent.url.toString(), isNot(contains(token)));
      expect(sent.body, isNot(contains(token)));
      for (final entry in sent.headers.entries) {
        if (entry.key != 'authorization') {
          expect(entry.value, isNot(contains(token)));
        }
      }
    });

    test('no token, no Authorization header', () async {
      late http.Request sent;
      await apiWith(answering(200, '{}', seen: (r) => sent = r)).get(['health']);
      expect(sent.headers.containsKey('authorization'), isFalse);
    });

    test('a "/" inside a path segment is sent as %2F', () async {
      late http.Request sent;
      await apiWith(answering(200, '{}', seen: (r) => sent = r))
          .get(['consignments', 'by-qr', 'QR/0042']);
      expect(sent.url.path, '/consignments/by-qr/QR%2F0042');
    });

    test('query values are encoded', () async {
      late http.Request sent;
      await apiWith(answering(200, '{}', seen: (r) => sent = r))
          .get(['alerts'], query: {'type': 'a&b=c'});
      expect(sent.url.query, 'type=a%26b%3Dc');
    });

    test('a body is sent as JSON', () async {
      late http.Request sent;
      await apiWith(answering(200, '{}', seen: (r) => sent = r))
          .put(['auth', 'me', 'public-key'], body: {'publicKey': 'abc'});
      expect(sent.method, 'PUT');
      expect(sent.headers['content-type'], startsWith('application/json'));
      expect(jsonDecode(sent.body), {'publicKey': 'abc'});
    });
  });

  group('exceptions become AppFailures', () {
    Future<AppFailure> whenServerThrows(Object error) => failureOf(
      () => apiWith(MockClient((_) async => throw error)).get(['x']),
    );

    test('HandshakeException -> InsecureConnection', () async {
      expect(
        await whenServerThrows(const HandshakeException('bad chain')),
        isA<InsecureConnection>(),
      );
    });

    test('any TlsException -> InsecureConnection', () async {
      expect(
        await whenServerThrows(const TlsException('nope')),
        isA<InsecureConnection>(),
      );
    });

    test('SocketException -> NoConnection', () async {
      expect(
        await whenServerThrows(const SocketException('no route')),
        isA<NoConnection>(),
      );
    });

    test('another ClientException -> NoConnection', () async {
      expect(
        await whenServerThrows(http.ClientException('connection closed')),
        isA<NoConnection>(),
      );
    });

    test('the time limit passing -> TimedOut, through the real trigger', () async {
      // A server that only reacts to the request's own abort trigger, as the
      // real IOClient does. The delay "finishes" at once, so the trigger
      // fires straight away.
      final slow = MockClient.streaming((request, _) async {
        await (request as http.Abortable).abortTrigger;
        throw http.RequestAbortedException(request.url);
      });
      final failure = await failureOf(
        () => apiWith(slow, delay: (_) async {}).get(['x']),
      );
      expect(failure, isA<TimedOut>());
    });

    test('the time limit given to a call is the one used', () async {
      Duration? asked;
      final api = apiWith(
        answering(200, '{}'),
        delay: (d) {
          asked = d;
          return Completer<void>().future;
        },
      );
      await api.get(['health'], timeout: const Duration(seconds: 90));
      expect(asked, const Duration(seconds: 90));

      await api.get(['x']);
      expect(asked, const Duration(seconds: 30));
    });
  });

  test('a failure\'s text has no body, message or token in it', () async {
    final api = apiWith(
      answering(401, envelope('TOKEN_INVALID', 'secret-message-text')),
    );
    final failure = await failureOf(() => api.get(['auth', 'me'], token: token));
    expect(failure.toString(), contains('401'));
    expect(failure.toString(), contains('TOKEN_INVALID'));
    expect(failure.toString(), isNot(contains('secret-message-text')));
    expect(failure.toString(), isNot(contains(token)));
  });

  group('session events', () {
    // The answers that end a session.
    const ending = {
      ApiCodes.tokenExpired: 401,
      ApiCodes.tokenInvalid: 401,
      ApiCodes.tokenMissing: 401,
      ApiCodes.accountPending: 403,
      ApiCodes.accountSuspended: 403,
      ApiCodes.accountRejected: 403,
      ApiCodes.accountNotActive: 403,
    };

    /// The codes SessionEvents announced while [action] ran.
    Future<List<String>> announcedDuring(
      SessionEvents events,
      Future<Object?> Function() action,
    ) async {
      final seen = <String>[];
      final subscription = events.refusals.listen(seen.add);
      await failureOf(action);
      // A broadcast stream delivers events a moment later, not at once.
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      return seen;
    }

    ending.forEach((code, status) {
      test('$status $code with a token is announced', () async {
        final events = SessionEvents();
        final api = apiWith(answering(status, envelope(code, 'm')), events: events);
        expect(
          await announcedDuring(events, () => api.get(['auth', 'me'], token: token)),
          [code],
        );
      });

      test('$status $code without a token is not announced', () async {
        final events = SessionEvents();
        final api = apiWith(answering(status, envelope(code, 'm')), events: events);
        expect(await announcedDuring(events, () => api.get(['auth', 'me'])), isEmpty);
      });
    });

    test('403 FORBIDDEN with a token is not announced', () async {
      final events = SessionEvents();
      final api = apiWith(
        answering(403, envelope(ApiCodes.forbidden, 'm')),
        events: events,
      );
      expect(
        await announcedDuring(events, () => api.get(['admin', 'users'], token: token)),
        isEmpty,
      );
    });

    test('401 INVALID_CREDENTIALS at login is not announced', () async {
      final events = SessionEvents();
      final api = apiWith(
        answering(401, envelope(ApiCodes.invalidCredentials, 'm')),
        events: events,
      );
      expect(
        await announcedDuring(events, () => api.post(['auth', 'login'], body: {})),
        isEmpty,
      );
    });

    test('the refusal is still thrown after it is announced', () async {
      final api = apiWith(answering(401, envelope(ApiCodes.tokenExpired, 'm')));
      final failure = await failureOf(() => api.get(['auth', 'me'], token: token));
      expect(
        failure,
        isA<ServerRefused>().having((f) => f.code, 'code', ApiCodes.tokenExpired),
      );
    });
  });
}
