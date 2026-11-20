// The six mineral chips, shared by "Register consignment" and, when the
// server could not say, "Take custody" (transporter handoff plan, Q1).

import 'package:flutter/material.dart';

import '../../../core/theme/sizes.dart';
import '../domain/mineral.dart';
import 'mineral_text.dart';

class MineralChips extends StatelessWidget {
  const MineralChips({
    required this.selected,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  final Mineral? selected;
  final ValueChanged<Mineral> onSelected;

  /// False while saving: every chip greyed out.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The fill and outline come from the theme's chipTheme. The label colour
    // is set here because a theme label style would replace the chip's own
    // text style instead of adding to it (see app_theme.dart).
    final label = WidgetStateColor.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return scheme.onSurface.withValues(alpha: 0.38);
      }
      if (states.contains(WidgetState.selected)) return scheme.onPrimary;
      return scheme.onSurface;
    });
    return Wrap(
      spacing: AppSizes.spaceS,
      runSpacing: AppSizes.spaceS,
      children: [
        for (final mineral in Mineral.values)
          // A chip is only 48 dp tall to the finger by default; the app's
          // minimum is 56 (gloves, dusty fingers). The chip grows to fill the
          // box, with its label centred.
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSizes.tapTargetMin),
            child: ChoiceChip(
              label: Text(mineralName(mineral)),
              labelStyle: TextStyle(color: label),
              selected: selected == mineral,
              // The chosen chip stands a little higher than the others.
              elevation: selected == mineral ? 4 : 2,
              // While saving, every chip is greyed out, and a white tick
              // would vanish on the grey.
              checkmarkColor: enabled ? scheme.onPrimary : scheme.onSurface,
              onSelected: enabled ? (_) => onSelected(mineral) : null,
            ),
          ),
      ],
    );
  }
}
