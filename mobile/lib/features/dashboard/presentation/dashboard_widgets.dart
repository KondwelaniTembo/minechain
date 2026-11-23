// The dashboard's building blocks (dashboard plan, T4, Q3 A): plain Flutter
// boxes in the theme's colours, no chart package. Every bar has its number in
// words beside it or a label for screen readers, so the page reads the same
// without the bars.

import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../domain/dashboard_summary.dart';

/// A card with a heading, as on the anchoring screen.
class DashboardSection extends StatelessWidget {
  const DashboardSection({
    required this.title,
    required this.children,
    super.key,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSizes.spaceM),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: AppSizes.spaceS),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// One row: its words and number on a line, a bar under them as long as
/// [count] is against [max].
class CountBar extends StatelessWidget {
  const CountBar({
    required this.label,
    required this.value,
    required this.count,
    required this.max,
    super.key,
  });

  final String label;

  /// The number in words, at the end of the line ("15", "12 steps, 6.5 kg").
  final String value;
  final int count;

  /// The largest count among the rows it is compared with.
  final int max;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSizes.spaceS),
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Wraps rather than cuts on a narrow phone or with large text.
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: AppSizes.spaceS,
              children: [
                Text(label, style: text.bodyLarge),
                Text(value, style: text.bodyMedium),
              ],
            ),
            const SizedBox(height: AppSizes.spaceXs),
            ExcludeSemantics(
              child: _Bar(
                fraction: max == 0 ? 0 : count / max,
                color: scheme.primary,
                track: scheme.surfaceContainerHighest,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.fraction,
    required this.color,
    required this.track,
  });

  final double fraction;
  final Color color;
  final Color track;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 8,
      decoration: BoxDecoration(
        color: track,
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: fraction.clamp(0, 1),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }
}

/// Steps per day or per week as upright bars, oldest on the left, with the
/// first and last day under them. Each bar has its own label for screen
/// readers ("17 Nov: 2 steps").
class StepBars extends StatelessWidget {
  const StepBars({required this.bars, super.key});

  final List<StepBucket> bars;

  static const double height = 120;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.bodySmall;
    final max = bars.fold(0, (m, b) => b.steps.total > m ? b.steps.total : m);
    final week = bars.any((b) => b.days > 1);
    // With the years when they differ: the phone check (T5) read "24 Nov …
    // 23 Nov" on 12 months as a period running backwards.
    final withYear = bars.first.start.year != bars.last.start.year;
    // Fewer, wider gaps when the bars are many (53 weeks).
    final gap = bars.length > 31 ? 1.0 : 2.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final bar in bars)
                Expanded(
                  child: Semantics(
                    key: ValueKey('bar-${bar.start.toIso8601String()}'),
                    label: AppText.barLabel(
                      bar.start,
                      week: week,
                      steps: bar.steps.total,
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: gap / 2),
                      child: FractionallySizedBox(
                        alignment: Alignment.bottomCenter,
                        // A day with no steps still shows a thin line, so
                        // the days are visible.
                        heightFactor: max == 0
                            ? 0.02
                            : (bar.steps.total / max).clamp(0.02, 1),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: bar.steps.total == 0
                                ? scheme.surfaceContainerHighest
                                : scheme.primary,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSizes.spaceXs),
        ExcludeSemantics(
          // Each date may wrap: with large text on a narrow phone the two
          // did not fit on one line (found by the text 2.0 test).
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  _short(bars.first.start, withYear: withYear),
                  style: text,
                ),
              ),
              const SizedBox(width: AppSizes.spaceS),
              Expanded(
                child: Text(
                  _short(bars.last.start, withYear: withYear),
                  style: text,
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// "17 Nov", or "24 Nov 2025" with the year.
  static String _short(DateTime day, {required bool withYear}) =>
      '${day.day} ${_months[day.month - 1]}${withYear ? ' ${day.year}' : ''}';
}

/// Choices where exactly one is always chosen (the period).
class OneOfChips<T extends Object> extends StatelessWidget {
  const OneOfChips({
    required this.label,
    required this.choices,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final String label;
  final Map<T, String> choices;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSizes.spaceS),
          Wrap(
            spacing: AppSizes.spaceS,
            runSpacing: AppSizes.spaceS,
            children: [
              for (final entry in choices.entries)
                ConstrainedBox(
                  // The app's 56 dp minimum (gloves, dusty fingers).
                  constraints: const BoxConstraints(
                    minHeight: AppSizes.tapTargetMin,
                  ),
                  child: ChoiceChip(
                    label: Text(entry.value),
                    selected: selected == entry.key,
                    onSelected: (_) => onSelected(entry.key),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
