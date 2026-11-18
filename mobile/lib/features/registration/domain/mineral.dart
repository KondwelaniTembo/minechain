// The minerals a consignment can be (api.md and the signing spec: "`gold`,
// `copper`, `cobalt`, `manganese`, `emerald` or `amethyst`"), and the unit
// the miner types the weight in (plan, Q2, approved 17 Nov 2026: "the unit
// follows the mineral").
//
// Plain Dart.

/// A weight unit, and how many decimals the miner may type in it. The number
/// of decimals is exactly what reaches whole milligrams: 1 g = 10^3 mg and
/// 1 kg = 10^6 mg, so grams allow 3 decimals and kilograms 6.
enum WeightUnit {
  grams(decimals: 3),
  kilograms(decimals: 6);

  const WeightUnit({required this.decimals});

  /// Digits allowed after the decimal point; also log10 of mg per unit.
  final int decimals;
}

/// The six minerals. Each name is exactly the API's value, so
/// `Mineral.gold.name` is what goes into the payload.
enum Mineral {
  // Small, valuable lots are weighed in grams.
  gold(WeightUnit.grams),
  emerald(WeightUnit.grams),
  amethyst(WeightUnit.grams),
  // Base metals and ores are weighed in kilograms.
  copper(WeightUnit.kilograms),
  cobalt(WeightUnit.kilograms),
  manganese(WeightUnit.kilograms);

  const Mineral(this.unit);

  final WeightUnit unit;

  /// The mineral named [name] exactly (the API's spelling), or null.
  static Mineral? fromApiName(String name) {
    for (final mineral in values) {
      if (mineral.name == name) return mineral;
    }
    return null;
  }
}
