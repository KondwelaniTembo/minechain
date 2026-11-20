// The weight field of every screen that signs a custody step (registration
// plan M5; shared since Transporter handoff T4). The unit follows the
// mineral: grams for gold and the gemstones, kilograms for the rest.

import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../../registration/domain/mineral.dart';
import '../../registration/domain/weight.dart';

/// The sentence under the weight field, if any. "Choose the mineral first"
/// shows at once (the unit depends on it); format problems only when
/// [showProblems]. Not while typing: "12." is on its way to "12.5", not a
/// mistake (found on the A57).
String? weightErrorText(
  String text,
  WeightUnit? unit, {
  required bool showProblems,
}) {
  if (text.trim().isEmpty) return null; // nothing typed yet
  if (unit == null) return AppText.chooseMineralFirst;
  if (!showProblems) return null;
  return switch (parseWeightToMg(text, unit)) {
    WeightRefused(problem: WeightProblem.empty) || WeightOk() => null,
    WeightRefused(problem: WeightProblem.negative) => AppText.weightNegative,
    WeightRefused(problem: WeightProblem.notANumber) =>
      AppText.weightNotANumber,
    WeightRefused(problem: WeightProblem.tooManyDecimals) =>
      AppText.weightTooManyDecimals(unit.decimals),
    WeightRefused(problem: WeightProblem.zero) => AppText.weightZero,
    WeightRefused(problem: WeightProblem.tooLarge) => AppText.weightTooLarge,
  };
}

class WeightField extends StatelessWidget {
  const WeightField({
    required this.unit,
    required this.controller,
    required this.focus,
    required this.enabled,
    required this.showProblems,
    required this.onChanged,
    super.key,
  });

  /// Null while no mineral is chosen.
  final WeightUnit? unit;
  final TextEditingController controller;
  final FocusNode focus;
  final bool enabled;
  final bool showProblems;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focus,
      enabled: enabled,
      // "Done" on the keyboard closes it, and leaving the field shows any
      // problem with what was typed.
      textInputAction: TextInputAction.done,
      // The number keyboard with a decimal key.
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      // No suggestions or learning: weights are not words, and the keyboard
      // must not remember them.
      autocorrect: false,
      enableSuggestions: false,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: unit == WeightUnit.kilograms
            ? AppText.weightInKilograms
            : AppText.weightInGrams,
        suffixText: unit == WeightUnit.kilograms
            ? AppText.kilograms
            : AppText.grams,
        errorText: weightErrorText(
          controller.text,
          unit,
          showProblems: showProblems,
        ),
        errorMaxLines: 3,
      ),
    );
  }
}
