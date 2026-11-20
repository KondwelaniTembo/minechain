// "My consignments" (plan M7): the miner's own registrations on this phone,
// newest first, each with its state in words and an icon, never colour
// alone (decision Mobile (34)). Since Transporter handoff T5 the same
// screen is the transporter's "My handoffs": [StepListKind] holds what
// differs (the step type, the words, the home and the way to add one).
// Buyer purchase T3 adds the buyer's "My purchases" the same way.
//
// Shown per record: the QR code, the mineral and weight, when it was saved,
// and the state in the words of "Send my work". A handoff's mineral is the
// unsigned hint the save used, so its weight shows in the unit the
// transporter typed. Never shown: the payload, signature, key fingerprint,
// coordinates or ids; the query does not even read them.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/clock.dart';
import '../../../core/database/database_failure.dart';
import '../../../core/errors/api_codes.dart';
import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../registration/domain/mineral.dart';
import '../../registration/domain/weight.dart';
import '../../registration/presentation/mineral_text.dart';
import '../../steps/domain/consignment_list_item.dart';
import 'my_consignments_provider.dart';

/// Which list the screen shows.
enum StepListKind {
  registrations(
    type: 'registration',
    title: AppText.myConsignments,
    empty: AppText.noConsignmentsYet,
    busy: AppText.consignmentsPhoneBusy,
    addLabel: AppText.registerConsignment,
    addPath: AppRoutes.minerRegister,
    addIcon: Icons.qr_code_scanner,
    homePath: AppRoutes.miner,
  ),
  handoffs(
    type: 'handoff',
    title: AppText.myHandoffs,
    empty: AppText.noHandoffsYet,
    busy: AppText.handoffsPhoneBusy,
    addLabel: AppText.takeCustody,
    addPath: AppRoutes.transporterCustody,
    addIcon: Icons.local_shipping,
    homePath: AppRoutes.transporter,
  ),
  // Buyer purchase T3: the buyer's purchases, the mineral from the hint as
  // for a handoff.
  purchases(
    type: 'purchase',
    title: AppText.myPurchases,
    empty: AppText.noPurchasesYet,
    busy: AppText.purchasesPhoneBusy,
    addLabel: AppText.recordPurchase,
    addPath: AppRoutes.buyerPurchase,
    addIcon: Icons.point_of_sale,
    homePath: AppRoutes.buyer,
  );

  const StepListKind({
    required this.type,
    required this.title,
    required this.empty,
    required this.busy,
    required this.addLabel,
    required this.addPath,
    required this.addIcon,
    required this.homePath,
  });

  /// The local step type listed.
  final String type;
  final String title;
  final String empty;
  final String busy;

  /// The empty list's button: the screen that saves this kind of step.
  final String addLabel;
  final String addPath;
  final IconData addIcon;

  /// Where the back arrow goes when there is no screen below.
  final String homePath;

  /// Each card's heading.
  String heading(String qrCode) => switch (this) {
    registrations => qrCode,
    handoffs => AppText.tookCustodyOf(qrCode),
    purchases => AppText.boughtRecord(qrCode),
  };
}

class MyConsignmentsScreen extends ConsumerWidget {
  const MyConsignmentsScreen({
    this.kind = StepListKind.registrations,
    super.key,
  });

  final StepListKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(myStepsProvider(kind.type));

    final Widget body;
    // While the list is read again after a send, the old one stays.
    if (items.hasValue) {
      final list = items.requireValue;
      body = list.isEmpty
          ? _Empty(kind)
          : _List(list, kind: kind, now: ref.watch(clockProvider)());
    } else if (items.hasError) {
      body = _Problem(items.error!, kind: kind);
    } else {
      body = const _Message(
        icon: Icons.hourglass_empty,
        text: AppText.openingSavedWork,
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => _back(context, kind)),
        title: Text(kind.title),
      ),
      body: SafeArea(child: body),
    );
  }
}

void _back(BuildContext context, StepListKind kind) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(kind.homePath);
  }
}

/// Opens the screen that saves this kind of step, and reads the list again
/// on the way back, whether or not a send has finished by then.
Future<void> _add(
  BuildContext context,
  WidgetRef ref,
  StepListKind kind,
) async {
  await context.push(kind.addPath);
  ref.invalidate(myStepsProvider(kind.type));
}

/// A centred, scrollable column for the states without a list, so large
/// text in landscape still fits.
class _Centred extends StatelessWidget {
  const _Centred({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(AppSizes.spaceM),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.error = false});
  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) =>
      _Centred(children: [_IconLine(icon, text, error: error)]);
}

class _Empty extends ConsumerWidget {
  const _Empty(this.kind);
  final StepListKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Centred(
    children: [
      _IconLine(Icons.inventory_2, kind.empty),
      const SizedBox(height: AppSizes.spaceM),
      FilledButton.icon(
        onPressed: () => _add(context, ref, kind),
        icon: Icon(kind.addIcon),
        label: Text(kind.addLabel),
      ),
    ],
  );
}

/// "Cannot be opened" only when it really cannot (Mobile (26)); anything
/// else is a busy moment, with a way to try again.
class _Problem extends ConsumerWidget {
  const _Problem(this.error, {required this.kind});
  final Object error;
  final StepListKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (savedWorkUnreadable(error)) {
      return const _Message(
        icon: Icons.storage,
        text: AppText.savedWorkProblem,
        error: true,
      );
    }
    return _Centred(
      children: [
        _IconLine(Icons.hourglass_empty, kind.busy),
        const SizedBox(height: AppSizes.spaceM),
        OutlinedButton.icon(
          onPressed: () => ref.invalidate(myStepsProvider(kind.type)),
          icon: const Icon(Icons.refresh),
          label: const Text(AppText.tryAgain),
        ),
      ],
    );
  }
}

class _List extends StatelessWidget {
  const _List(this.items, {required this.kind, required this.now});
  final List<ConsignmentListItem> items;
  final StepListKind kind;
  final DateTime now;

  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: const EdgeInsets.all(AppSizes.spaceM),
    itemCount: items.length,
    itemBuilder: (context, index) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: _Item(items[index], kind: kind, now: now),
      ),
    ),
  );
}

class _Item extends StatelessWidget {
  const _Item(this.item, {required this.kind, required this.now});
  final ConsignmentListItem item;
  final StepListKind kind;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final status = item.statusAt(now);
    final message = item.lastMessage;
    return Card(
      key: ValueKey(item.stepId),
      margin: const EdgeInsets.only(bottom: AppSizes.spaceS),
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.spaceM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              kind.heading(item.qrCode),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSizes.spaceS),
            Text(_what(item)),
            Text(AppText.savedAt(item.createdAt.toLocal())),
            const SizedBox(height: AppSizes.spaceS),
            _IconLine(
              _statusIcon(status),
              _statusText(status, item.lastCode),
              error:
                  status == StepStatus.rejected || status == StepStatus.stuck,
            ),
            // The server's message, as given (plan §3). None after a
            // duplicate answer: it carries no message (decision Mobile (34)).
            if (status == StepStatus.underReview &&
                message != null &&
                message.isNotEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: AppSizes.spaceL + AppSizes.spaceS,
                ),
                child: Text(message),
              ),
          ],
        ),
      ),
    );
  }
}

/// "Gold, 1.5 g": the unit follows the mineral (Q2), exact from the signed
/// milligrams. A mineral or weight this app does not know (a damaged row)
/// is shown as stored, in milligrams; with no mineral at all, the weight
/// alone, in milligrams.
String _what(ConsignmentListItem item) {
  final stored = item.mineral;
  if (stored == null) return '${item.weightMg} ${AppText.milligrams}';
  final mineral = Mineral.fromApiName(stored);
  if (mineral != null) {
    final weight = weightInUnit(item.weightMg, mineral.unit);
    if (weight != null) {
      return AppText.consignmentWhat(
        mineralName(mineral),
        weight,
        unitSymbol(mineral.unit),
      );
    }
  }
  return AppText.consignmentWhat(
    mineral == null ? stored : mineralName(mineral),
    item.weightMg,
    AppText.milligrams,
  );
}

IconData _statusIcon(StepStatus status) => switch (status) {
  StepStatus.waiting => Icons.phone_android,
  StepStatus.stuck => Icons.schedule,
  StepStatus.sent => Icons.cloud_done,
  StepStatus.underReview => Icons.policy,
  StepStatus.rejected => Icons.block,
};

String _statusText(StepStatus status, String? code) => switch (status) {
  StepStatus.waiting => AppText.stepWaiting,
  StepStatus.stuck => AppText.stepStuck,
  StepStatus.sent => AppText.stepSent,
  StepStatus.underReview => AppText.stepUnderReview,
  StepStatus.rejected when code == ApiCodes.payloadUnsupportedVersion =>
    AppText.stepUpdateApp,
  StepStatus.rejected => AppText.stepRejected(code ?? '?'),
};

/// An icon and a sentence, never colour alone (as on "Send my work").
class _IconLine extends StatelessWidget {
  const _IconLine(this.icon, this.text, {this.error = false});
  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? Theme.of(context).colorScheme.error : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(child: Icon(icon, color: color)),
        const SizedBox(width: AppSizes.spaceS),
        Expanded(
          child: Text(text, style: TextStyle(color: color)),
        ),
      ],
    );
  }
}
