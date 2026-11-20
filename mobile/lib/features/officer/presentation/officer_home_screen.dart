// The regulatory officer's home (plan section 4.2). Placeholder tiles for now:
// each says "Coming soon" until its module is built. "Check a consignment"
// (consignment check plan) and "Alerts" (officer alerts plan) are built.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/widgets/coming_soon.dart';
import '../../../core/widgets/home_scaffold.dart';
import '../../auth/presentation/home_header.dart';

class OfficerHomeScreen extends ConsumerWidget {
  const OfficerHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void soon() => showComingSoon(context);

    return HomeScaffold(
      title: AppText.officerTitle,
      username: watchUsername(ref),
      header: const HomeHeader(),
      // push (not go): the account screen goes on top of this home, so its
      // back arrow and Android's back button return here.
      // go(), not push(): Account is a place of the navigation bar, and the
      // bar then shows it as chosen (Mobile (37), Q9).
      onAccountPressed: () => context.go(AppRoutes.account),
      actions: [
        HomeAction(
          icon: Icons.notification_important,
          label: AppText.alerts,
          // push(): a task page over the home (officer alerts plan, T2).
          onTap: () => context.push(AppRoutes.officerAlerts),
          primary: true,
        ),
        HomeAction(
          icon: Icons.fact_check,
          label: AppText.checkConsignment,
          // push(): a task page over the home, whose back arrow returns here.
          onTap: () => context.push(AppRoutes.officerCheck),
        ),
        HomeAction(
          icon: Icons.table_chart,
          label: AppText.reports,
          onTap: soon,
        ),
        HomeAction(icon: Icons.history, label: AppText.auditTrail, onTap: soon),
      ],
    );
  }
}
