// AdminZonesApi and AdminZonesRepository against the fake zones server (GPS
// zones plan, T1): what is sent (path, query, token, exact body bytes), and
// what each answer becomes.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/network/pinned_http_client.dart';
import 'package:minechain/features/admin/data/admin_zones_api.dart';
import 'package:minechain/features/admin/data/admin_zones_repository.dart';
import 'package:minechain/features/admin/domain/gps_zone.dart';

import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_zones_server.dart';

void main() {
  late FakeZonesServer server;
  late AdminZonesRepository repository;

  setUp(() {
    server = FakeZonesServer();
    repository = AdminZonesRepository(
      api: () async => AdminZonesApi(server.apiClient()),
    );
  });

  const corners = [
    ZoneCorner(-13.45, 25.82),
    ZoneCorner(-13.47, 25.86),
    ZoneCorner(-13.49, 25.81),
  ];

  Matcher refusedWith(String code) =>
      throwsA(isA<ServerRefused>().having((f) => f.code, 'code', code));

  group('zones', () {
    test('asks for one status, 20 at a time, with the token', () async {
      final page = await repository.zones(
        token: fakeToken,
        status: ZoneStatus.active,
      );
      final sent = server.lists.single;
      expect(sent.url.path, '/admin/zones');
      expect(sent.url.queryParameters, {
        'status': 'active',
        'limit': '20',
        'offset': '0',
      });
      expect(sent.headers['authorization'], 'Bearer $fakeToken');
      // By name, ignoring letter case, as the server sends them.
      expect(page.zones.map((z) => z.name), [
        'Kasempa North',
        'ZCAS Campus (demo)',
      ]);
      expect(page.total, 2);
    });

    test('inactive, and the offset', () async {
      final page = await repository.zones(
        token: fakeToken,
        status: ZoneStatus.inactive,
        offset: 20,
      );
      expect(server.lists.single.url.queryParameters, {
        'status': 'inactive',
        'limit': '20',
        'offset': '20',
      });
      expect(page.zones, isEmpty);
      expect(page.total, 1);
    });

    test('one unreadable zone makes the page unreadable', () async {
      server.zones.add({...zoneJson(9), 'boundary': 'none'});
      expect(
        () => repository.zones(token: fakeToken, status: ZoneStatus.active),
        throwsA(isA<BadResponse>()),
      );
    });

    test('an answer without a list or a total is unreadable', () async {
      for (final body in <Object>[
        {'zones': []},
        {'total': 1},
        {'zones': 'none', 'total': 1},
        {'zones': [], 'total': -1},
        [1, 2],
      ]) {
        server.answers['list'] = (_) => json200(body);
        await expectLater(
          repository.zones(token: fakeToken, status: ZoneStatus.active),
          throwsA(isA<BadResponse>()),
          reason: '$body',
        );
      }
    });
  });

  group('create', () {
    test('the exact body: numbers, latitude first, trimmed text', () async {
      final zone = await repository.create(
        token: fakeToken,
        name: '  Kafue Gorge  ',
        licenceNumber: ' DEMO-LML-0009 ',
        boundary: corners,
      );
      final sent = server.creates.single;
      expect(sent.url.path, '/admin/zones');
      expect(sent.headers['authorization'], 'Bearer $fakeToken');
      // The bytes the server reads: corners as JSON numbers, never text.
      expect(
        sent.body,
        '{"name":"Kafue Gorge","licenceNumber":"DEMO-LML-0009",'
        '"boundary":[[-13.45,25.82],[-13.47,25.86],[-13.49,25.81]]}',
      );
      expect(zone.name, 'Kafue Gorge');
      expect(zone.status, ZoneStatus.active);
      expect(zone.boundary, corners);
    });

    test('no licence number, or only spaces: the field is left out', () async {
      for (final licence in [null, '', '   ']) {
        await repository.create(
          token: fakeToken,
          name: 'Zone ${licence?.length}',
          licenceNumber: licence,
          boundary: corners,
        );
        final body =
            jsonDecode(server.creates.last.body) as Map<String, Object?>;
        expect(body.keys, ['name', 'boundary'], reason: '"$licence"');
      }
    });

    test('six decimals are sent as they are', () async {
      await repository.create(
        token: fakeToken,
        name: 'Campus corner',
        licenceNumber: null,
        boundary: const [
          ZoneCorner(-15.418327, 28.289494),
          ZoneCorner(-15.418544, 28.288),
          ZoneCorner(-15.419519, 28.287099),
        ],
      );
      expect(
        server.creates.single.body,
        contains(
          '[[-15.418327,28.289494],[-15.418544,28.288],'
          '[-15.419519,28.287099]]',
        ),
      );
    });

    test('a taken name, any letter case, inactive zones included', () async {
      for (final name in ['kasempa north', 'MUMBWA EAST']) {
        await expectLater(
          repository.create(
            token: fakeToken,
            name: name,
            licenceNumber: null,
            boundary: corners,
          ),
          refusedWith(ApiCodes.zoneNameTaken),
        );
      }
    });

    test("the server's field details reach the caller", () async {
      server.answers['create'] = (_) => boundaryRefusal({
        'boundary.3': 'repeats the first corner; list each corner once',
      });
      try {
        await repository.create(
          token: fakeToken,
          name: 'Closed ring',
          licenceNumber: null,
          boundary: corners,
        );
        fail('no refusal');
      } on ServerRefused catch (failure) {
        expect(failure.code, ApiCodes.validationFailed);
        expect(failure.details.single.field, 'boundary.3');
      }
    });

    test('a 201 without a readable zone is an odd answer', () async {
      server.answers['create'] = (_) => http.Response(
        jsonEncode({'zone': null}),
        201,
        headers: {'content-type': 'application/json'},
      );
      expect(
        () => repository.create(
          token: fakeToken,
          name: 'Odd',
          licenceNumber: null,
          boundary: corners,
        ),
        throwsA(isA<BadResponse>()),
      );
    });
  });

  group('rename', () {
    test('path and trimmed body; the new zone back', () async {
      final zone = await repository.rename(
        token: fakeToken,
        id: zoneId(1),
        name: ' Kasempa North (until Nov 2026) ',
      );
      final sent = server.actions('rename').single;
      expect(sent.url.path, '/admin/zones/${zoneId(1)}/rename');
      expect(sent.body, '{"name":"Kasempa North (until Nov 2026)"}');
      expect(zone.name, 'Kasempa North (until Nov 2026)');
    });

    test("a letter-case change of the zone's own name is allowed", () async {
      final zone = await repository.rename(
        token: fakeToken,
        id: zoneId(1),
        name: 'KASEMPA NORTH',
      );
      expect(zone.name, 'KASEMPA NORTH');
    });

    test("another zone's name is taken; an unknown id is not found", () async {
      await expectLater(
        repository.rename(token: fakeToken, id: zoneId(1), name: 'mumbwa east'),
        refusedWith(ApiCodes.zoneNameTaken),
      );
      await expectLater(
        repository.rename(token: fakeToken, id: zoneId(99), name: 'Anything'),
        refusedWith(ApiCodes.zoneNotFound),
      );
    });
  });

  group('deactivate', () {
    test(
      'path and trimmed reason; no warning while others are active',
      () async {
        final answer = await repository.deactivate(
          token: fakeToken,
          id: zoneId(1),
          reason: '  Licence revoked  ',
        );
        final sent = server.actions('deactivate').single;
        expect(sent.url.path, '/admin/zones/${zoneId(1)}/deactivate');
        expect(sent.body, '{"reason":"Licence revoked"}');
        expect(answer.zone.status, ZoneStatus.inactive);
        expect(answer.warning, isNull);
      },
    );

    test('the last active zone: the warning comes back', () async {
      await repository.deactivate(
        token: fakeToken,
        id: zoneId(1),
        reason: 'Licence revoked',
      );
      final last = await repository.deactivate(
        token: fakeToken,
        id: zoneId(2),
        reason: 'Campus demo over',
      );
      expect(last.warning!.code, 'NO_ACTIVE_ZONES');
      expect(last.warning!.message, noActiveZonesMessage);
    });

    test('an inactive zone: INVALID_STATUS_TRANSITION', () async {
      await expectLater(
        repository.deactivate(token: fakeToken, id: zoneId(3), reason: 'Again'),
        refusedWith(ApiCodes.invalidStatusTransition),
      );
    });
  });

  group('reactivate', () {
    test('no body; active again', () async {
      final zone = await repository.reactivate(token: fakeToken, id: zoneId(3));
      final sent = server.actions('reactivate').single;
      expect(sent.url.path, '/admin/zones/${zoneId(3)}/reactivate');
      expect(sent.body, isEmpty);
      expect(zone.status, ZoneStatus.active);
    });

    test('an active zone: INVALID_STATUS_TRANSITION', () async {
      await expectLater(
        repository.reactivate(token: fakeToken, id: zoneId(1)),
        refusedWith(ApiCodes.invalidStatusTransition),
      );
    });
  });

  test('a pinning set-up failure is an insecure connection', () async {
    final broken = AdminZonesRepository(
      api: () async => throw PinningSetupError('no certificates'),
    );
    await expectLater(
      broken.zones(token: fakeToken, status: ZoneStatus.active),
      throwsA(isA<InsecureConnection>()),
    );
    await expectLater(
      broken.reactivate(token: fakeToken, id: zoneId(1)),
      throwsA(isA<InsecureConnection>()),
    );
  });
}
