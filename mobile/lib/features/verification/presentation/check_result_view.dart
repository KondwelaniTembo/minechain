// The answer to "Check a consignment" (consignment check plan §4, T4): the
// verdict banner, the consignment, then one card per custody step in the
// order the server sent them.
//
// The page draws only what the answer holds. The server already cut the
// answer down for the viewer's role, so a field that is absent (a blind
// transporter's weights, a buyer's coordinates) is simply not drawn; the page
// never guesses at it. The role differences (T5) follow from that too: the
// "weigh it first" line comes from `weightsHidden`, the location from
// `location`, and the officer's review details from `reviewStatus`,
// `alerts` and `check.fields`, never from the viewer's role in the app.
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
        // Held with nothing listed: everyone but an officer is sent only
        // accepted steps, so a consignment whose registration is under
        // review comes with none. Without this line the page just looked
        // empty under "Under review" (A57 check, 20 Nov).
        if (view.held && view.steps.isEmpty) ...[
          const SizedBox(height: AppSizes.spaceS),
          const _IconLine(Icons.visibility_off, AppText.stepsHiddenWhileHeld),
        ],
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
        // A transporter who has not weighed yet sees no weight and no hash
        // (the hash leads to the on-chain weight), so they measure without
        // knowing the expected figure and the 10% rule cannot be gamed.
        // Not while held: the line would invite them to take custody of a
        // consignment an officer is reviewing (A57 check, 20 Nov).
        if (view.weightsHidden && !view.held) ...[
          const SizedBox(height: AppSizes.spaceS),
          _IconLine(
            Icons.scale,
            AppText.weighFirst,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
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
    final location = step.location;
    final hash = step.chainTxHash;
    final review = step.reviewStatus;
    // Officers only: a rejected step never goes on the blockchain, so its
    // lines never say "yet".
    final rejected = review == ReviewStatus.rejected;
    final alerts = step.alerts;
    final fields = step.mismatchFields;
    final reason = step.mismatchReason;
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
            // Officers and the owning buyer only.
            if (location != null)
              Text(AppText.locationLine(location.latitude, location.longitude)),
            Text(AppText.recordedAt(step.capturedAt.toLocal())),
            const SizedBox(height: AppSizes.spaceS),
            _CheckLine(step.check, rejected: rejected),
            // Officers only, on a mismatch: what differs, by name. The
            // server never sends the values, and neither does this page.
            if (fields != null && fields.isNotEmpty)
              Text(AppText.whatDiffers(fields.join(', '))),
            if (reason != null) Text(AppText.mismatchReason(reason)),
            // Officers only. A flagged or rejected step is listed for them
            // too, so its review status is the first thing they read here.
            if (review != null) ...[
              const SizedBox(height: AppSizes.spaceS),
              _ReviewLine(review),
            ],
            if (alerts != null)
              Text(
                AppText.alertsLine(
                  alerts.length,
                  alerts.where((a) => a.status == 'open').length,
                ),
              ),
            // The hash only when the answer has the key (a blind transporter
            // does not get it); null there means nothing was sent yet.
            if (step.chainTxHashShown) ...[
              const SizedBox(height: AppSizes.spaceS),
              // A rejected step's check line already says it never goes.
              if (hash == null && !rejected)
                const Text(AppText.notSentYet)
              else if (hash != null) ...[
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

class _ReviewLine extends StatelessWidget {
  const _ReviewLine(this.review);
  final ReviewStatus review;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, text, colour) = switch (review) {
      ReviewStatus.passed => (
        Icons.rule,
        AppText.reviewPassed,
        scheme.onSurface,
      ),
      ReviewStatus.cleared => (
        Icons.task_alt,
        AppText.reviewCleared,
        scheme.onSurface,
      ),
      ReviewStatus.flagged => (Icons.flag, AppText.reviewFlagged, scheme.error),
      ReviewStatus.rejected => (
        Icons.block,
        AppText.reviewRejected,
        scheme.error,
      ),
    };
    return _IconLine(icon, text, colour: colour);
  }
}

/// An icon and a sentence, never colour alone.
class _IconLine extends StatelessWidget {
  const _IconLine(this.icon, this.text, {this.colour, this.style});
  final IconData icon;
  final String text;
  final Color? colour;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(child: Icon(icon, color: colour)),
        const SizedBox(width: AppSizes.spaceS),
        Expanded(
          child: Text(
            text,
            style: (style ?? const TextStyle()).copyWith(color: colour),
          ),
        ),
      ],
    );
  }
}

class _CheckLine extends StatelessWidget {
  const _CheckLine(this.result, {required this.rejected});
  final CheckResult result;
  final bool rejected;

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
      CheckResult.notAnchoredYet when rejected => (
        Icons.block,
        AppText.stepRejectedNeverAnchored,
        scheme.onSurface,
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
    return _IconLine(icon, text, colour: colour);
  }
}
