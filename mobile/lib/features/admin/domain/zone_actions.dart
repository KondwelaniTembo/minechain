// Which actions a zone's page offers, by its status (GPS zones plan §3):
//
//   | Status   | Rename | Deactivate | Reactivate |
//   | active   | ✓      | ✓          |            |
//   | inactive | ✓      |            | ✓          |
//
// The boundary and the licence number never change (Scope (7)), so there is
// no "edit" beyond the name, and a zone is never deleted. The app hides what
// the server would refuse; if the server refuses anyway (another
// administrator acted first), its sentence is shown.
//
// Plain Dart, no Flutter.

import 'gps_zone.dart';

enum ZoneAction { rename, deactivate, reactivate }

/// The buttons in the order the page shows them: the status change last.
List<ZoneAction> zoneActionsFor(GpsZone zone) => switch (zone.status) {
  ZoneStatus.active => const [ZoneAction.rename, ZoneAction.deactivate],
  ZoneStatus.inactive => const [ZoneAction.rename, ZoneAction.reactivate],
};
