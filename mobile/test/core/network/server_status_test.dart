// ServerStatusController with a pretend server and pretend time.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/network/api_client.dart';
import 'package:minechain/core/network/network_providers.dart';
import 'package:minechain/core/network/server_status.dart';
import 'package:minechain/core/network/session_events.dart';
import 'package:minechain/core/riverpod/no_retry.dart';

/// A container whose API talks to [server], and whose "3 seconds" end when
/// [wake] completes (never, if not given).
ProviderContainer containerFor(MockClient server, {Completer<void>? wake}) {
  final api = ApiClient(
    client: server,
    baseUri: Uri.parse('https://api.example.test'),
    sessionEvents: SessionEvents(),
    delay: (_) => Completer<void>().future, // requests never time out here
  );
  return ProviderContainer.test(
    retry: noRetry,
    overrides: [
      apiClientProvider.overrideWith((ref) => api),
      serverCheckTimingProvider.overrideWithValue(
        ServerCheckTiming(delay: (_) => (wake ?? Completer<void>()).future),
      ),
    ],
  );
}

ServerStatusController controllerOf(ProviderContainer c) =>
    c.read(serverStatusControllerProvider.notifier);

ServerStatus statusOf(ProviderContainer c) =>
    c.read(serverStatusControllerProvider);

void main() {
  test('starts as unknown', () {
    final c = containerFor(MockClient((_) async => http.Response('{}', 200)));
    expect(statusOf(c), isA<ServerUnknown>());
  });

  test('200 {"status":"ok"} -> ready', () async {
    final c = containerFor(
      MockClient((_) async => http.Response('{"status":"ok"}', 200)),
    );
    await controllerOf(c).check();
    expect(statusOf(c), isA<ServerReady>());
  });

  test('503 -> not ready', () async {
    final c = containerFor(
      MockClient(
        (_) async => http.Response('{"status":"error","database":"down"}', 503),
      ),
    );
    await controllerOf(c).check();
    expect(statusOf(c), isA<ServerNotReady>());
  });

  test('no network -> failed, with NoConnection', () async {
    final c = containerFor(
      MockClient((_) async => throw const SocketException('no route')),
    );
    await controllerOf(c).check();
    expect(
      statusOf(c),
      isA<ServerFailed>().having(
        (s) => s.failure,
        'failure',
        isA<NoConnection>(),
      ),
    );
  });

  test('200 with another body -> failed, BadResponse', () async {
    final c = containerFor(
      MockClient((_) async => http.Response('{"status":"maybe"}', 200)),
    );
    await controllerOf(c).check();
    expect(
      statusOf(c),
      isA<ServerFailed>().having((s) => s.failure, 'failure', isA<BadResponse>()),
    );
  });

  test('no answer in time -> waking, then ready when it answers', () async {
    final wake = Completer<void>();
    final answer = Completer<http.Response>();
    final c = containerFor(MockClient((_) => answer.future), wake: wake);

    final running = controllerOf(c).check();
    expect(statusOf(c), isA<ServerChecking>());

    wake.complete(); // "3 seconds" pass with no answer
    await Future<void>.delayed(Duration.zero);
    expect(statusOf(c), isA<ServerWaking>());

    answer.complete(http.Response('{"status":"ok"}', 200));
    await running;
    expect(statusOf(c), isA<ServerReady>());
  });

  test('an answer before the threshold never shows waking', () async {
    final wake = Completer<void>();
    final c = containerFor(
      MockClient((_) async => http.Response('{"status":"ok"}', 200)),
      wake: wake,
    );
    await controllerOf(c).check();
    wake.complete(); // the "3 seconds" end after the answer
    await Future<void>.delayed(Duration.zero);
    expect(statusOf(c), isA<ServerReady>());
  });

  test('a second check while one is running does nothing', () async {
    var requests = 0;
    final answer = Completer<http.Response>();
    final c = containerFor(
      MockClient((_) {
        requests++;
        return answer.future;
      }),
    );

    final first = controllerOf(c).check();
    await Future<void>.delayed(Duration.zero); // let it reach the server
    await controllerOf(c).check(); // returns at once
    answer.complete(http.Response('{"status":"ok"}', 200));
    await first;

    expect(requests, 1);
    expect(statusOf(c), isA<ServerReady>());
  });

  test('after a check finishes, another one runs', () async {
    var requests = 0;
    final c = containerFor(
      MockClient((_) async {
        requests++;
        return http.Response('{"status":"ok"}', 200);
      }),
    );
    await controllerOf(c).check();
    await controllerOf(c).check();
    expect(requests, 2);
  });
}
