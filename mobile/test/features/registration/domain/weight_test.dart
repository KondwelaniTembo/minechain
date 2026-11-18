// The typed weight to whole milligrams, exactly (plan Q2: the unit follows
// the mineral).

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/registration/domain/weight.dart';

void main() {
  group('the unit follows the mineral', () {
    for (final (mineral, unit) in [
      (Mineral.gold, WeightUnit.grams),
      (Mineral.emerald, WeightUnit.grams),
      (Mineral.amethyst, WeightUnit.grams),
      (Mineral.copper, WeightUnit.kilograms),
      (Mineral.cobalt, WeightUnit.kilograms),
      (Mineral.manganese, WeightUnit.kilograms),
    ]) {
      test('${mineral.name} -> ${unit.name}', () => expect(mineral.unit, unit));
    }

    test('exactly the six minerals the API allows, with its spelling', () {
      expect(Mineral.values.map((m) => m.name).toSet(), {
        'gold',
        'copper',
        'cobalt',
        'manganese',
        'emerald',
        'amethyst',
      });
      expect(Mineral.fromApiName('Gold'), isNull); // never case-folded
    });
  });

  group('accepted', () {
    for (final (typed, unit, mg) in [
      ('1.5', WeightUnit.kilograms, '1500000'),
      ('1,5', WeightUnit.kilograms, '1500000'), // a comma keyboard
      ('1.1', WeightUnit.kilograms, '1100000'), // a classic double trap
      ('0.000001', WeightUnit.kilograms, '1'), // 1 mg, the smallest
      ('2', WeightUnit.kilograms, '2000000'),
      ('250', WeightUnit.grams, '250000'),
      ('0.5', WeightUnit.grams, '500'),
      ('0.001', WeightUnit.grams, '1'),
      ('12.345', WeightUnit.grams, '12345'),
      ('007', WeightUnit.grams, '7000'), // leading zeros are dropped
      (' 1.5 ', WeightUnit.kilograms, '1500000'), // the field's padding
      ('9223372036854.775807', WeightUnit.kilograms, '9223372036854775807'),
    ]) {
      test('"$typed" ${unit.name} -> $mg mg', () {
        final result = parseWeightToMg(typed, unit);
        expect(result, isA<WeightOk>());
        expect((result as WeightOk).milligrams, mg);
      });
    }
  });

  group('refused', () {
    for (final (typed, unit, problem) in [
      ('', WeightUnit.grams, WeightProblem.empty),
      ('   ', WeightUnit.grams, WeightProblem.empty),
      ('-1', WeightUnit.grams, WeightProblem.negative),
      ('-0.5', WeightUnit.kilograms, WeightProblem.negative),
      ('0', WeightUnit.grams, WeightProblem.zero),
      ('0.000', WeightUnit.grams, WeightProblem.zero),
      ('0.0000001', WeightUnit.kilograms, WeightProblem.tooManyDecimals),
      ('0.0005', WeightUnit.grams, WeightProblem.tooManyDecimals),
      ('1.2345', WeightUnit.grams, WeightProblem.tooManyDecimals),
      ('9223372036854.775808', WeightUnit.kilograms, WeightProblem.tooLarge),
      ('99999999999999999999', WeightUnit.grams, WeightProblem.tooLarge),
      ('1.5.2', WeightUnit.grams, WeightProblem.notANumber),
      ('1,000.5', WeightUnit.grams, WeightProblem.notANumber), // thousands
      ('1 000', WeightUnit.grams, WeightProblem.notANumber),
      ('+1', WeightUnit.grams, WeightProblem.notANumber),
      ('.5', WeightUnit.grams, WeightProblem.notANumber),
      ('5.', WeightUnit.grams, WeightProblem.notANumber),
      ('1e3', WeightUnit.grams, WeightProblem.notANumber),
      ('abc', WeightUnit.grams, WeightProblem.notANumber),
      ('١٢', WeightUnit.grams, WeightProblem.notANumber), // other digits
    ]) {
      test('"$typed" ${unit.name} -> ${problem.name}', () {
        final result = parseWeightToMg(typed, unit);
        expect(result, isA<WeightRefused>());
        expect((result as WeightRefused).problem, problem);
      });
    }
  });

  // "My consignments" shows the signed milligrams in the mineral's unit.
  group('weightInUnit', () {
    for (final (mg, unit, shown) in [
      ('1500', WeightUnit.grams, '1.5'),
      ('1500000', WeightUnit.grams, '1500'),
      ('1', WeightUnit.grams, '0.001'),
      ('1100000', WeightUnit.kilograms, '1.1'),
      ('2000000', WeightUnit.kilograms, '2'),
      ('1', WeightUnit.kilograms, '0.000001'),
      ('9223372036854775807', WeightUnit.grams, '9223372036854775.807'),
    ]) {
      test('$mg mg in ${unit.name} is "$shown", and back again', () {
        expect(weightInUnit(mg, unit), shown);
        // Exact both ways: what is shown parses back to the signed text.
        expect((parseWeightToMg(shown, unit) as WeightOk).milligrams, mg);
      });
    }

    test('not plain digits (a damaged row): null', () {
      expect(weightInUnit('1.5', WeightUnit.grams), isNull);
      expect(weightInUnit('', WeightUnit.grams), isNull);
      expect(weightInUnit('-1', WeightUnit.grams), isNull);
    });
  });
}
