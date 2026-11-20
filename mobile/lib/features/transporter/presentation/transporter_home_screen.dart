// The transporter's home (plan section 4.2). Every tile is built: "Take
// custody", "My handoffs" and "Send my work" (transporter handoff plan),
// and "Check a consignment" (consignment check plan).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/widgets/home_scaffold.dart';
import '../../auth/presentation/home_header.dart';

class TransporterHomeScreen extends ConsumerWidget {
  const TransporterHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HomeScaffold(
      title: AppText.transporterTitle,
      username: watchUsername(ref),
      header: const HomeHeader(),
      // push (not go): the account screen goes on top of this home, so its
      // back arrow and Android's back button return here.
      // go(), not push(): Account is a place of the navigation bar, and the
      // bar then shows it as chosen (Mobile (37), Q9).
      onAccountPressed: () => context.go(AppRoutes.account),
      actions: [
        HomeAction(
          icon: Icons.local_shipping,
          label: AppText.takeCustody,
          // push(): a task page over the home, whose back arrow returns here.
          onTap: () => context.push(AppRoutes.transporterCustody),
          primary: true,
        ),
        HomeAction(
          icon: Icons.fact_check,
          label: AppText.checkConsignment,
          // push(): a task page over the home, whose back arrow returns here.
          onTap: () => context.push(AppRoutes.transporterCheck),
        ),
        HomeAction(
          icon: Icons.list_alt,
          label: AppText.myHandoffs,
          onTap: () => context.push(AppRoutes.transporterHandoffs),
        ),
        HomeAction(
          icon: Icons.cloud_upload,
          label: AppText.sendMyWork,
          onTap: () => context.push(AppRoutes.transporterSync),
        ),
      ],
    );
  }
}
