// AdminAnchoringApi and AdminAnchoringRepository against the fake anchoring
// server (anchoring status plan, T2): what is sent, and what each answer
// becomes.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/network/pinned_http_client.dart';
import 'package:minechain/features/admin/data/admin_anchoring_api.dart';
import 'package:minechain/features/admin/data/admin_anchoring_repository.dart';
import 'package:minechain/features/admin/domain/anchoring_status.dart';

import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_admin_server.dart' show refusal;
import '../../../fakes/fake_anchoring_server.dart';

void main() {
  late FakeAnchoringServer server;
  late AdminAnchoringRepository repository;

  setUp(() {
    server = FakeAnchoringServer(stuckExampleJson());
    repository = AdminAnchoringRepository(
      api: () async => AdminAnchoringApi(server.apiClient()),
    );
  });

  test('one GET, no query, with the token; the answer read', () async {
    final status = await repository.status(token: fakeToken);

    final sent = server.received.single;
    expect(sent.method, 'GET');
    expect(sent.url.path, '/admin/anchoring');
    // Any parameter is refused by the server.
    expect(sent.url.query, isEmpty);
    expect(sent.headers['authorization'], 'Bearer $fakeToken');
    expect(status.state, WorkerState.running);
    expect(status.inFlight.single.stuck, isTrue);
  });

  test('FORBIDDEN is passed on as the server refused it', () async {
    server.answer = (_) =>
        refusal(403, ApiCodes.forbidden, 'You do not have permission.');

    await expectLater(
      repository.status(token: fakeToken),
      throwsA(
        isA<ServerRefused>().having((f) => f.code, 'code', ApiCodes.forbidden),
      ),
    );
  });

  test('an answer that is not the documented shape is a BadResponse', () async {
    server.answer = (_) => http.Response(
      '{"worker": {"state": "running"}}',
      200,
      headers: {'content-type': 'application/json'},
    );

    await expectLater(
      repository.status(token: fakeToken),
      throwsA(isA<BadResponse>()),
    );
  });

  test('a pinning set-up failure is an insecure connection', () async {
    final insecure = AdminAnchoringRepository(
      api: () async => throw PinningSetupError('no certificates'),
    );

    await expectLater(
      insecure.status(token: fakeToken),
      throwsA(isA<InsecureConnection>()),
    );
  });
}
