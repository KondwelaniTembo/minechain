// The pieces both alert pages use (officer alerts plan, T2 and T3): the
// card in the list, the info lines, the state message, and the small words
// built from an alert (its step, who recorded it, the decision).

import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../account/presentation/account_screen.dart' show roleLabel;
import '../../registration/presentation/mineral_text.dart';
import '../../verification/domain/consignment_view.dart'
    show ConsignmentStage, StepType;
import '../domain/alert.dart';
import 'alert_words.dart';

/// A large icon, a sentence and, optionally, a button: the empty, failed and
/// needs-password states. Shared with the alert's own page.
class AlertStateMessage extends StatelessWidget {
  const AlertStateMessage({
    required this.icon,
    required this.text,
    this.action,
    super.key,
  });

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSizes.spaceXl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeSemantics(child: Icon(icon, size: AppSizes.tileIcon)),
          const SizedBox(height: AppSizes.spaceM),
          // liveRegion: TalkBack reads the new state out when it appears.
          Semantics(
            liveRegion: true,
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: AppSizes.spaceM),
            action!,
          ],
        ],
      ),
    );
  }
}

// ---- One alert's card ---------------------------------------------------------

/// The severity's icon, so it is never told by colour alone.
IconData severityIcon(AlertSeverity severity) => switch (severity) {
  AlertSeverity.high => Icons.error,
  AlertSeverity.medium => Icons.warning_amber,
  AlertSeverity.low => Icons.info_outline,
};

String stepWord(Alert alert) => switch (alert.step.type) {
  StepType.registration => AppText.stepRegistration,
  StepType.handoff => AppText.stepHandoff,
  StepType.purchase => AppText.stepPurchase,
};

/// "Handoff by transporter patsani".
String stepByWhom(Alert alert) => AppText.stepByWhom(
  stepWord(alert),
  roleLabel(alert.actor.role).toLowerCase(),
  alert.actor.username,
);

/// "Confirmed by officer_chanda, 20 Nov, 15:00", or null while open.
String? decisionLine(Alert alert) {
  final review = alert.review;
  if (review == null) return null;
  return switch (alert.status) {
    AlertStatus.reviewed => AppText.confirmedBy(
      review.byUsername,
      review.at.toLocal(),
    ),
    AlertStatus.dismissed => AppText.clearedBy(
      review.byUsername,
      review.at.toLocal(),
    ),
    AlertStatus.open => null,
  };
}

class AlertCard extends StatelessWidget {
  const AlertCard({required this.alert, required this.onTap, super.key});

  final Alert alert;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final decision = decisionLine(alert);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      alertHeading(alert.type),
                      style: text.titleMedium,
                    ),
                  ),
                  const ExcludeSemantics(child: Icon(Icons.chevron_right)),
                ],
              ),
              const SizedBox(height: AppSizes.spaceS),
              AlertInfoLine(
                icon: severityIcon(alert.severity),
                text: severityWord(alert.severity),
              ),
              AlertInfoLine(
                icon: Icons.qr_code,
                text: AppText.alertConsignment(
                  alert.consignment.qrCode,
                  mineralName(alert.consignment.mineral),
                ),
              ),
              AlertInfoLine(icon: Icons.person, text: stepByWhom(alert)),
              AlertInfoLine(
                icon: Icons.event,
                // The phone's own time zone, for the person reading it.
                text: AppText.raisedAt(alert.createdAt.toLocal()),
              ),
              if (decision != null)
                AlertInfoLine(icon: Icons.gavel, text: decision),
              // Only an open alert holds anything. A closed one on a held
              // consignment is not what holds it (another open alert is),
              // so the line would blame the wrong alert (T5 on the A57).
              if (alert.isOpen && alert.consignment.held)
                const AlertInfoLine(
                  icon: Icons.pause_circle,
                  text: AppText.holdsConsignment,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class AlertInfoLine extends StatelessWidget {
  const AlertInfoLine({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSizes.spaceXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 20)),
          const SizedBox(width: AppSizes.spaceS),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class SmallSpinner extends StatelessWidget {
  const SmallSpinner({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}

/// The stage in the consignment check's words ("On its way").
String stageWord(ConsignmentStage stage) => switch (stage) {
  ConsignmentStage.registered => AppText.stageRegistered,
  ConsignmentStage.inTransit => AppText.stageInTransit,
  ConsignmentStage.purchased => AppText.stagePurchased,
};
