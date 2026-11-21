// The small words and icons the "GPS zones" pages build from a zone (GPS
// zones plan, T2 and T3).
//
// In presentation, not domain, because the words come from AppText.

import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../domain/gps_zone.dart';

/// The chip's label: "Active".
String zoneChipLabel(ZoneStatus status) => switch (status) {
  ZoneStatus.active => AppText.zonesActive,
  ZoneStatus.inactive => AppText.zonesInactive,
};

/// The word inside a sentence: "2 active zones.", "No inactive zones."
String zoneStatusWord(ZoneStatus status) => zoneChipLabel(status).toLowerCase();

IconData zoneStatusIcon(ZoneStatus status) => switch (status) {
  ZoneStatus.active => Icons.check_circle,
  ZoneStatus.inactive => Icons.pause_circle,
};
