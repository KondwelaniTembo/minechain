// ConsignmentCheckApi and ConsignmentCheckRepository against the fake server:
// what is sent (path, token, method, no body), and what each answer becomes.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/network/pinned_http_client.dart';
import 'package:minechain/features/verification/data/consignment_check_api.dart';
import 'package:minechain/features/verification/data/consignment_check_repository.dart';
import 'package:minechain/features/verification/domain/consignment_view.dart';

import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_admin_server.dart' show json200, refusal;
import '../../../fakes/fake_check_server.dart';

void main() {
  late FakeCheckServer server;
  late ConsignmentCheckRepository repository;

  setUp(() {
    server = FakeCheckServer();
    repository = ConsignmentCheckRepository(
      api: () async => ConsignmentCheckApi(server.apiClient()),
    );
  });

  test('GETs /consignments/by-qr/{code} with the token and no body', () async {
    final view = await repository.check(token: fakeToken, qrCode: knownQrCode);

    final sent = server.requests.single;
    expect(sent.method, 'GET');
    expect(sent.url.path, '/consignments/by-qr/$knownQrCode');
    expect(sent.url.query, isEmpty);
    expect(sent.headers['authorization'], 'Bearer $fakeToken');
    expect(sent.body, isEmpty);

    expect(view.qrCode, knownQrCode);
    expect(view.stage, ConsignmentStage.inTransit);
    expect(view.steps.map((s) => s.type), [
      StepType.registration,
      StepType.handoff,
    ]);
  });

  test('a "/" in a code is sent as %2F, as api.md requires', () async {
    server.answer = (_) =>
        json200(consignmentAnswerJson(qrCode: 'MC/2026/001'));

    await repository.check(token: fakeToken, qrCode: 'MC/2026/001');

    final url = server.requests.single.url;
    expect(url.toString(), endsWith('/consignments/by-qr/MC%2F2026%2F001'));
    expect(url.pathSegments, ['consignments', 'by-qr', 'MC/2026/001']);
  });

  test('one request per check: nothing is retried', () async {
    server.answer = (_) => http.Response('oops', 500);
    await expectLater(
      repository.check(token: fakeToken, qrCode: knownQrCode),
      throwsA(isA<AppFailure>()),
    );
    expect(server.requests, hasLength(1));
  });

  group('refusals come through as ServerRefused, code unchanged', () {
    for (final (status, code) in [
      (404, 'CONSIGNMENT_NOT_FOUND'),
      (403, 'FORBIDDEN'),
      (400, 'VALIDATION_FAILED'),
    ]) {
      test('$status $code', () async {
        server.answer = (_) => refusal(status, code, 'Server words.');
        await expectLater(
          repository.check(token: fakeToken, qrCode: knownQrCode),
          throwsA(
            isA<ServerRefused>()
                .having((f) => f.status, 'status', status)
                .having((f) => f.code, 'code', code)
                .having((f) => f.serverMessage, 'message', 'Server words.'),
          ),
        );
      });
    }

    test('429 keeps Retry-After', () async {
      server.answer = (_) => http.Response(
        '{"error":{"code":"TOO_MANY_REQUESTS","message":"Too many '
        'consignment scans. Please wait a few minutes and try again."}}',
        429,
        headers: {'retry-after': '120'},
      );
      await expectLater(
        repository.check(token: fakeToken, qrCode: knownQrCode),
        throwsA(
          isA<ServerRefused>()
              .having((f) => f.code, 'code', 'TOO_MANY_REQUESTS')
              .having(
                (f) => f.retryAfter,
                'retryAfter',
                const Duration(seconds: 120),
              ),
        ),
      );
    });

    test('the default fake: an unknown code is 404', () async {
      await expectLater(
        repository.check(token: fakeToken, qrCode: 'MC-2026-LSK-9999'),
        throwsA(
          isA<ServerRefused>().having(
            (f) => f.code,
            'code',
            'CONSIGNMENT_NOT_FOUND',
          ),
        ),
      );
    });
  });

  group('an unreadable 200 is BadResponse, never a partial answer', () {
    for (final (name, body) in <(String, Object)>[
      ('an empty object', <String, Object?>{}),
      ('a list', <Object?>[]),
      (
        'an unknown check result',
        consignmentAnswerJson(steps: [checkedStepJson(check: 'looks_ok')]),
      ),
      (
        'one good step and one unreadable one',
        consignmentAnswerJson(
          steps: [
            checkedStepJson(),
            {'id': 'x'},
          ],
        ),
      ),
    ]) {
      test(name, () async {
        server.answer = (_) => json200(body);
        await expectLater(
          repository.check(token: fakeToken, qrCode: knownQrCode),
          throwsA(isA<BadResponse>()),
        );
      });
    }
  });

  test('a pinning set-up failure becomes InsecureConnection', () async {
    final broken = ConsignmentCheckRepository(
      api: () async => throw PinningSetupError('test'),
    );
    await expectLater(
      broken.check(token: fakeToken, qrCode: knownQrCode),
      throwsA(isA<InsecureConnection>()),
    );
  });
}
