// The words for a mineral and its unit, shared by the registration screen
// and "My consignments", so a mineral is named the same everywhere.

import '../../../core/text/app_text.dart';
import '../domain/mineral.dart';

String mineralName(Mineral mineral) => switch (mineral) {
  Mineral.gold => AppText.gold,
  Mineral.copper => AppText.copper,
  Mineral.cobalt => AppText.cobalt,
  Mineral.manganese => AppText.manganese,
  Mineral.emerald => AppText.emerald,
  Mineral.amethyst => AppText.amethyst,
};

String unitSymbol(WeightUnit unit) =>
    unit == WeightUnit.kilograms ? AppText.kilograms : AppText.grams;
