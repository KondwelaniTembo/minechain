// Which buttons a zone's page shows, by status (GPS zones plan §3, T3).

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/admin/domain/gps_zone.dart';
import 'package:minechain/features/admin/domain/zone_actions.dart';

import '../../../fakes/fake_zones_server.dart';

void main() {
  test('active: rename, then deactivate', () {
    final zone = GpsZone.fromJson(zoneJson(1))!;
    expect(zoneActionsFor(zone), [ZoneAction.rename, ZoneAction.deactivate]);
  });

  test('inactive: rename, then reactivate', () {
    final zone = GpsZone.fromJson(zoneJson(1, status: 'inactive'))!;
    expect(zoneActionsFor(zone), [ZoneAction.rename, ZoneAction.reactivate]);
  });

  test('never an edit of the boundary or a delete', () {
    expect(ZoneAction.values, [
      ZoneAction.rename,
      ZoneAction.deactivate,
      ZoneAction.reactivate,
    ]);
  });
}
