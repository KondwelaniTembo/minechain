// The answer to "Check a consignment" (consignment check plan §4, T4): the
// verdict banner, the consignment, then one card per custody step in the
// order the server sent them.
//
// The page draws only what the answer holds. The server already cut the
// answer down for the viewer's role, so a field that is absent (a blind
// transporter's weights, a buyer's coordinates) is simply not drawn; the page
// never guesses at it. Role-specific lines (the "weigh it first" line, the
// officer's review details) come in T5.
//
// Status is never shown by colour alone (decision Mobile (35)): each banner
// and each step's check has an icon and words as well.

import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/sizes.dart';
import '../../account/presentation/account_screen.dart' show roleLabel;
import '../../registration/domain/mineral.dart';
import '../../registration/domain/weight.dart';
import '../../registration/presentation/mineral_text.dart';
import '../domain/consignment_view.dart';
import '../domain/verdict.dart';

/// The banner's background and text colours for [verdict].
///
/// Only pairs from the app's theme, so the contrast checks in
/// app_theme_test.dart and check_result_view_test.dart cover them:
/// red for a mismatch, light copper for "under review" (the theme has no
/// separate amber; copper is its notice colour), patina green for verified,
/// and a plain raised surface for the three "nothing wrong, just not
/// finished" cases.
({Color background, Color foreground}) verdictColours(
  Verdict verdict,
  ColorScheme scheme,
) => switch (verdict) {
  Verdict.mismatch => (
    background: scheme.errorContainer,
    foreground: scheme.onErrorContainer,
  ),
  Verdict.underReview => (
    background: scheme.primaryContainer,
    foreground: scheme.onPrimaryContainer,
  ),
  Verdict.chainUnavailable ||
  Verdict.notAnchoredYet ||
  Verdict.nothingToCheck => (
    background: scheme.surfaceContainerHighest,
    foreground: scheme.onSurface,
  ),
  Verdict.verified => (
    background: scheme.tertiaryContainer,
    foreground: scheme.onTertiaryContainer,
  ),
};

String verdictText(Verdict verdict) => switch (verdict) {
  Verdict.mismatch => AppText.verdictMismatch,
  Verdict.underReview => AppText.verdictUnderReview,
  Verdict.chainUnavailable => AppText.verdictChainUnavailable,
  Verdict.notAnchoredYet => AppText.verdictNotAnchoredYet,
  Verdict.nothingToCheck => AppText.verdictNothingToCheck,
  Verdict.verified => AppText.verdictVerified,
};

IconData _verdictIcon(Verdict verdict) => switch (verdict) {
  Verdict.mismatch => Icons.gpp_bad,
  Verdict.underReview => Icons.policy,
  Verdict.chainUnavailable => Icons.cloud_off,
  Verdict.notAnchoredYet => Icons.hourglass_top,
  Verdict.nothingToCheck => Icons.info_outline,
  Verdict.verified => Icons.verified,
};

/// The whole result. [footer] (the "Scan again" button) goes last.
class CheckResultView extends StatelessWidget {
  const CheckResultView({super.key, required this.view, required this.footer});

  final ConsignmentView view;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VerdictBanner(verdict: verdictFor(view)),
        const SizedBox(height: AppSizes.spaceM),
        _ConsignmentBlock(view),
        if (view.steps.isNotEmpty) ...[
          const SizedBox(height: AppSizes.spaceM),
          Semantics(
            header: true,
            child: Text(
              AppText.custodySteps,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: AppSizes.spaceS),
          for (final step in view.steps) _StepCard(step, mineral: view.mineral),
        ],
        const SizedBox(height: AppSizes.spaceM),
        footer,
      ],
    );
  }
}

class VerdictBanner extends StatelessWidget {
  const VerdictBanner({super.key, required this.verdict});
  final Verdict verdict;

  @override
  Widget build(BuildContext context) {
    final colours = verdictColours(verdict, Theme.of(context).colorScheme);
    // liveRegion: TalkBack reads the verdict out when the answer arrives,
    // as it does for the server status banner.
    return Semantics(
      liveRegion: true,
      child: Material(
        color: colours.background,
        elevation: 2,
        shadowColor: AppTheme.shadow,
        borderRadius: BorderRadius.circular(AppSizes.tileRadius),
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _verdictIcon(verdict),
                color: colours.foreground,
                size: AppSizes.statusIcon,
              ),
              const SizedBox(width: AppSizes.spaceM),
              Expanded(
                child: Text(
                  verdictText(verdict),
                  style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(color: colours.foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The QR code, the mineral and where the consignment is in its journey.
class _ConsignmentBlock extends StatelessWidget {
  const _ConsignmentBlock(this.view);
  final ConsignmentView view;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(view.qrCode, style: Theme.of(context).textTheme.titleLarge),
        Text(mineralName(view.mineral)),
        Text(AppText.stageLine(_stageWord(view.stage))),
      ],
    );
  }
}

String _stageWord(ConsignmentStage stage) => switch (stage) {
  ConsignmentStage.registered => AppText.stageRegistered,
  ConsignmentStage.inTransit => AppText.stageInTransit,
  ConsignmentStage.purchased => AppText.stagePurchased,
};

class _StepCard extends StatelessWidget {
  const _StepCard(this.step, {required this.mineral});
  final CheckedStep step;
  final Mineral mineral;

  @override
  Widget build(BuildContext context) {
    final weight = step.weightMg;
    final hash = step.chainTxHash;
    return Card(
      key: ValueKey(step.id),
      margin: const EdgeInsets.only(bottom: AppSizes.spaceS),
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.spaceM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              stepHeadline(step),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSizes.spaceS),
            if (weight != null) Text(AppText.weightLine(_weight(weight))),
            Text(
              step.zoneName == null
                  ? AppText.outsideEveryZone
                  : AppText.zoneLine(step.zoneName!),
            ),
            Text(AppText.recordedAt(step.capturedAt.toLocal())),
            const SizedBox(height: AppSizes.spaceS),
            _CheckLine(step.check),
            // The hash only when the answer has the key (a blind transporter
            // does not get it); null there means nothing was sent yet.
            if (step.chainTxHashShown) ...[
              const SizedBox(height: AppSizes.spaceS),
              if (hash == null)
                const Text(AppText.notSentYet)
              else ...[
                const Text(AppText.blockchainTransaction),
                // Selectable, so it can be copied into Etherscan (Q4). It is
                // 66 characters with no spaces, so it breaks anywhere.
                SelectableText(
                  hash,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// "1500 g" in the mineral's unit, exact from the milligrams; milligrams
  /// if the text cannot be shown in the unit (it always can after fromJson).
  String _weight(String milligrams) {
    final inUnit = weightInUnit(milligrams, mineral.unit);
    return inUnit == null
        ? '$milligrams ${AppText.milligrams}'
        : '$inUnit ${unitSymbol(mineral.unit)}';
  }
}

/// "Registered by miner mutale_banda", "Handed off to you", "Bought by a
/// buyer" (no username for a transporter viewer).
String stepHeadline(CheckedStep step) {
  final who = step.byYou
      ? AppText.you
      : AppText.actorName(
          roleLabel(step.actor.role).toLowerCase(),
          step.actor.username,
        );
  return switch (step.type) {
    StepType.registration => AppText.registeredBy(who),
    StepType.handoff => AppText.handedOffTo(who),
    StepType.purchase => AppText.boughtBy(who),
  };
}

class _CheckLine extends StatelessWidget {
  const _CheckLine(this.result);
  final CheckResult result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, text, colour) = switch (result) {
      CheckResult.match => (
        Icons.check_circle,
        AppText.stepMatches,
        scheme.tertiary,
      ),
      CheckResult.mismatch => (
        Icons.cancel,
        AppText.stepMismatch,
        scheme.error,
      ),
      CheckResult.notAnchoredYet => (
        Icons.hourglass_top,
        AppText.stepNotAnchoredYet,
        scheme.onSurface,
      ),
      CheckResult.chainUnavailable => (
        Icons.cloud_off,
        AppText.stepChainUnavailable,
        scheme.onSurface,
      ),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(child: Icon(icon, color: colour)),
        const SizedBox(width: AppSizes.spaceS),
        Expanded(
          child: Text(text, style: TextStyle(color: colour)),
        ),
      ],
    );
  }
}
