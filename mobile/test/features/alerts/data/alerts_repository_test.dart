// AlertsApi and AlertsRepository against the fake server: what is sent
// (path, query, token, body), and what each answer becomes (officer alerts
// plan, T1).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/network/pinned_http_client.dart';
import 'package:minechain/features/alerts/data/alerts_api.dart';
import 'package:minechain/features/alerts/data/alerts_repository.dart';
import 'package:minechain/features/alerts/domain/alert.dart';
import 'package:minechain/features/verification/domain/consignment_view.dart';

import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_admin_server.dart' show json200, refusal;
import '../../../fakes/fake_alerts_server.dart';

void main() {
  late FakeAlertsServer server;
  late AlertsRepository repository;

  setUp(() {
    server = FakeAlertsServer([
      alertJson(1),
      alertJson(2, status: 'dismissed'),
      alertJson(
        3,
        type: 'handoff_order',
        severity: 'high',
        details: {'consignmentStage': 'purchased', 'stepType': 'handoff'},
      ),
    ]);
    repository = AlertsRepository(
      api: () async => AlertsApi(server.apiClient()),
    );
  });

  group('alerts', () {
    test('asks for open alerts, 20 at a time, with the token', () async {
      final page = await repository.alerts(
        token: fakeToken,
        status: AlertStatus.open,
      );

      final sent = server.lists.single;
      expect(sent.url.path, '/alerts');
      expect(sent.url.queryParameters, {
        'status': 'open',
        'limit': '20',
        'offset': '0',
      });
      expect(sent.headers['authorization'], 'Bearer $fakeToken');
      expect(page.alerts.map((a) => a.id), [alertId(1), alertId(3)]);
      expect(page.total, 2);
    });

    test('the closed statuses use their API names', () async {
      await repository.alerts(token: fakeToken, status: AlertStatus.reviewed);
      await repository.alerts(token: fakeToken, status: AlertStatus.dismissed);
      expect(server.lists.map((r) => r.url.queryParameters['status']), [
        'reviewed',
        'dismissed',
      ]);
    });

    test('passes the offset for the next page', () async {
      await repository.alerts(
        token: fakeToken,
        status: AlertStatus.open,
        offset: 20,
      );
      expect(server.lists.single.url.queryParameters['offset'], '20');
    });

    for (final (name, body) in <(String, Object)>[
      ('no alerts list', {'total': 1}),
      ('no total', {'alerts': <Object>[]}),
      ('a negative total', {'alerts': <Object>[], 'total': -1}),
      ('a body that is not a map', 'alerts'),
      (
        'one unreadable alert',
        {
          'alerts': [
            alertJson(1),
            {'id': 'x'},
          ],
          'total': 2,
        },
      ),
    ]) {
      test('$name -> BadResponse', () async {
        server.listAnswer = (_) => json200(body);
        await expectLater(
          repository.alerts(token: fakeToken, status: AlertStatus.open),
          throwsA(isA<BadResponse>()),
        );
      });
    }

    test('a refusal comes through as ServerRefused', () async {
      server.listAnswer = (_) => refusal(403, 'FORBIDDEN');
      await expectLater(
        repository.alerts(token: fakeToken, status: AlertStatus.open),
        throwsA(
          isA<ServerRefused>()
              .having((f) => f.status, 'status', 403)
              .having((f) => f.code, 'code', 'FORBIDDEN'),
        ),
      );
    });

    test('a pinning set-up failure becomes InsecureConnection', () async {
      final broken = AlertsRepository(
        api: () async => throw PinningSetupError('no roots'),
      );
      await expectLater(
        broken.alerts(token: fakeToken, status: AlertStatus.open),
        throwsA(isA<InsecureConnection>()),
      );
    });
  });

  group('alert', () {
    test(
      'GET /alerts/{id}, with the other alerts on the consignment',
      () async {
        final alert = await repository.alert(token: fakeToken, id: alertId(1));

        expect(server.details.single.url.path, '/alerts/${alertId(1)}');
        expect(
          server.details.single.headers['authorization'],
          'Bearer $fakeToken',
        );
        expect(alert.id, alertId(1));
        expect(alert.otherAlerts!.map((o) => o.id), [alertId(2), alertId(3)]);
      },
    );

    test('a detail without otherAlerts -> BadResponse', () async {
      server.detailAnswer = (_) => json200({'alert': alertJson(1)});
      await expectLater(
        repository.alert(token: fakeToken, id: alertId(1)),
        throwsA(isA<BadResponse>()),
      );
    });

    test('an unreadable alert -> BadResponse', () async {
      server.detailAnswer = (_) => json200({'alert': 'x'});
      await expectLater(
        repository.alert(token: fakeToken, id: alertId(1)),
        throwsA(isA<BadResponse>()),
      );
    });

    test('404 ALERT_NOT_FOUND comes through', () async {
      await expectLater(
        repository.alert(token: fakeToken, id: alertId(9)),
        throwsA(
          isA<ServerRefused>().having((f) => f.code, 'code', 'ALERT_NOT_FOUND'),
        ),
      );
    });
  });

  group('the decisions', () {
    test(
      'confirmProblem: POST .../review with exactly the trimmed notes',
      () async {
        final result = await repository.confirmProblem(
          token: fakeToken,
          id: alertId(1),
          notes: '  Weighed again: load short\n',
        );

        final sent = server.reviews.single;
        expect(sent.method, 'POST');
        expect(sent.url.path, '/alerts/${alertId(1)}/review');
        expect(sent.headers['authorization'], 'Bearer $fakeToken');
        expect(jsonDecode(sent.body), {'notes': 'Weighed again: load short'});
        expect(result.stepStatus, ReviewStatus.rejected);
        expect(result.stage, ConsignmentStage.registered);
        // Alert 3 on the same consignment is still open, so it stays held.
        expect(result.held, isTrue);
      },
    );

    test('clear: POST .../dismiss; a handoff moves the stage', () async {
      final result = await repository.clear(
        token: fakeToken,
        id: alertId(1),
        notes: 'Scale checked at the depot',
      );

      final sent = server.dismissals.single;
      expect(sent.url.path, '/alerts/${alertId(1)}/dismiss');
      expect(jsonDecode(sent.body), {'notes': 'Scale checked at the depot'});
      expect(result.stepStatus, ReviewStatus.cleared);
      expect(result.stage, ConsignmentStage.inTransit);
      // Alert 3 on the same consignment is still open.
      expect(result.held, isTrue);
    });

    test('line breaks inside the notes are kept', () async {
      await repository.clear(
        token: fakeToken,
        id: alertId(1),
        notes: 'Line one\nLine two',
      );
      expect(jsonDecode(server.dismissals.single.body), {
        'notes': 'Line one\nLine two',
      });
    });

    test('an odd 200 answer is still a decision, with nulls', () async {
      server.reviewAnswer = (_) => json200({'ok': true});
      final result = await repository.confirmProblem(
        token: fakeToken,
        id: alertId(1),
        notes: 'Load short',
      );
      expect(result.stepStatus, isNull);
      expect(result.held, isNull);
    });

    test('409 INVALID_STATUS_TRANSITION on an alert already closed', () async {
      await expectLater(
        repository.confirmProblem(
          token: fakeToken,
          id: alertId(2),
          notes: 'Load short',
        ),
        throwsA(
          isA<ServerRefused>()
              .having((f) => f.status, 'status', 409)
              .having((f) => f.code, 'code', 'INVALID_STATUS_TRANSITION'),
        ),
      );
    });

    test('409 STEP_CANNOT_BE_CLEARED keeps the server message', () async {
      await expectLater(
        repository.clear(token: fakeToken, id: alertId(3), notes: 'Fine'),
        throwsA(
          isA<ServerRefused>()
              .having((f) => f.code, 'code', 'STEP_CANNOT_BE_CLEARED')
              .having(
                (f) => f.serverMessage,
                'serverMessage',
                contains('Confirm the problem instead.'),
              ),
        ),
      );
    });

    test('429 carries Retry-After', () async {
      server.reviewAnswer = (_) => http.Response(
        errorAnswer('TOO_MANY_REQUESTS', 'Too many alert decisions.'),
        429,
        headers: {'retry-after': '120'},
      );
      await expectLater(
        repository.confirmProblem(
          token: fakeToken,
          id: alertId(1),
          notes: 'Load short',
        ),
        throwsA(
          isA<ServerRefused>().having(
            (f) => f.retryAfter,
            'retryAfter',
            const Duration(seconds: 120),
          ),
        ),
      );
    });
  });
}
