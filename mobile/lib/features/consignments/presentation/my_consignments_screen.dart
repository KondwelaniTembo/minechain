// "My consignments" (plan M7): the miner's own registrations on this phone,
// newest first, each with its state in words and an icon, never colour
// alone (decision Mobile (34)).
//
// Shown per record: the QR code, the mineral and weight, when it was saved,
// and the state in the words of "Send my work". Never shown: the payload,
// signature, key fingerprint, coordinates or ids; the query does not even
// read them.

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

class MyConsignmentsScreen extends ConsumerWidget {
  const MyConsignmentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(myConsignmentsProvider);

    final Widget body;
    // While the list is read again after a send, the old one stays.
    if (items.hasValue) {
      final list = items.requireValue;
      body = list.isEmpty
          ? const _Empty()
          : _List(list, now: ref.watch(clockProvider)());
    } else if (items.hasError) {
      body = _Problem(items.error!);
    } else {
      body = const _Message(
        icon: Icons.hourglass_empty,
        text: AppText.openingSavedWork,
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => _back(context)),
        title: const Text(AppText.myConsignments),
      ),
      body: SafeArea(child: body),
    );
  }
}

void _back(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(AppRoutes.miner);
  }
}

/// Opens the registration screen, and reads the list again on the way
/// back, whether or not a send has finished by then.
Future<void> _register(BuildContext context, WidgetRef ref) async {
  await context.push(AppRoutes.minerRegister);
  ref.invalidate(myConsignmentsProvider);
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
  const _Empty();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Centred(
    children: [
      const _IconLine(Icons.inventory_2, AppText.noConsignmentsYet),
      const SizedBox(height: AppSizes.spaceM),
      FilledButton.icon(
        onPressed: () => _register(context, ref),
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text(AppText.registerConsignment),
      ),
    ],
  );
}

/// "Cannot be opened" only when it really cannot (Mobile (26)); anything
/// else is a busy moment, with a way to try again.
class _Problem extends ConsumerWidget {
  const _Problem(this.error);
  final Object error;

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
        const _IconLine(Icons.hourglass_empty, AppText.consignmentsPhoneBusy),
        const SizedBox(height: AppSizes.spaceM),
        OutlinedButton.icon(
          onPressed: () => ref.invalidate(myConsignmentsProvider),
          icon: const Icon(Icons.refresh),
          label: const Text(AppText.tryAgain),
        ),
      ],
    );
  }
}

class _List extends StatelessWidget {
  const _List(this.items, {required this.now});
  final List<ConsignmentListItem> items;
  final DateTime now;

  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: const EdgeInsets.all(AppSizes.spaceM),
    itemCount: items.length,
    itemBuilder: (context, index) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: _Item(items[index], now: now),
      ),
    ),
  );
}

class _Item extends StatelessWidget {
  const _Item(this.item, {required this.now});
  final ConsignmentListItem item;
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
            Text(item.qrCode, style: Theme.of(context).textTheme.titleMedium),
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
/// is shown as stored, in milligrams.
String _what(ConsignmentListItem item) {
  final mineral = Mineral.fromApiName(item.mineral);
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
    mineral == null ? item.mineral : mineralName(mineral),
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
