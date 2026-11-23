// DashboardApi and DashboardRepository against the fake dashboard server
// (dashboard plan, T3): what is sent, and what each answer becomes.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/network/pinned_http_client.dart';
import 'package:minechain/features/dashboard/data/dashboard_api.dart';
import 'package:minechain/features/dashboard/data/dashboard_repository.dart';
import 'package:minechain/features/dashboard/domain/dashboard_period.dart';
import 'package:minechain/features/registration/domain/mineral.dart';

import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_admin_server.dart' show refusal;
import '../../../fakes/fake_dashboard_server.dart';

void main() {
  late FakeDashboardServer server;
  late DashboardRepository repository;

  setUp(() {
    server = FakeDashboardServer();
    repository = DashboardRepository(
      api: () async => DashboardApi(server.apiClient()),
      clock: () => DateTime.utc(2026, 11, 23, 12),
    );
  });

  test('one GET with the period, no mineral, and the token', () async {
    final summary = await repository.summary(
      token: fakeToken,
      query: const DashboardQuery(period: DashboardPeriod.week),
    );

    final sent = server.received.single;
    expect(sent.method, 'GET');
    expect(sent.url.path, '/dashboard');
    expect(sent.url.queryParameters, {
      'from': '2026-11-17',
      'to': '2026-11-23',
    });
    expect(sent.headers['authorization'], 'Bearer $fakeToken');
    expect(summary.days, 7);
  });

  test('the mineral and a longer period', () async {
    final summary = await repository.summary(
      token: fakeToken,
      query: const DashboardQuery(
        period: DashboardPeriod.month,
        mineral: Mineral.gold,
      ),
    );

    expect(server.received.single.url.queryParameters, {
      'from': '2026-10-25',
      'to': '2026-11-23',
      'mineral': 'gold',
    });
    expect(summary.days, 30);
    expect(summary.mineral, Mineral.gold);
  });

  test('FORBIDDEN is passed on as the server refused it', () async {
    server.answer = (_) =>
        refusal(403, ApiCodes.forbidden, 'You do not have permission.');

    await expectLater(
      repository.summary(
        token: fakeToken,
        query: const DashboardQuery(period: DashboardPeriod.week),
      ),
      throwsA(
        isA<ServerRefused>().having((f) => f.code, 'code', ApiCodes.forbidden),
      ),
    );
  });

  test('an answer that is not the documented shape is a BadResponse', () async {
    server.answer = (_) => http.Response(
      '{"period": {"from": "2026-11-17"}}',
      200,
      headers: {'content-type': 'application/json'},
    );

    await expectLater(
      repository.summary(
        token: fakeToken,
        query: const DashboardQuery(period: DashboardPeriod.week),
      ),
      throwsA(isA<BadResponse>()),
    );
  });

  test('a pinning set-up failure is an insecure connection', () async {
    final insecure = DashboardRepository(
      api: () async => throw PinningSetupError('no certificates'),
    );

    await expectLater(
      insecure.summary(
        token: fakeToken,
        query: const DashboardQuery(period: DashboardPeriod.week),
      ),
      throwsA(isA<InsecureConnection>()),
    );
  });
}
