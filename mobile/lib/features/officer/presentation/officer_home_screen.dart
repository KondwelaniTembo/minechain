// The regulatory officer's home (plan section 4.2). Every tile is built:
// "Check a consignment" (consignment check plan), "Alerts" (officer alerts
// plan), "Dashboard" (dashboard plan, T4), "Reports" and "Audit trail"
// (reports plan, T3 and T4).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/widgets/home_scaffold.dart';
import '../../auth/presentation/home_header.dart';

class OfficerHomeScreen extends ConsumerWidget {
  const OfficerHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          icon: Icons.insights,
          label: AppText.dashboard,
          // push(): a task page over the home (dashboard plan, T4).
          onTap: () => context.push(AppRoutes.officerDashboard),
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
          // push(): a task page over the home (reports plan, T3).
          onTap: () => context.push(AppRoutes.officerReports),
        ),
        HomeAction(
          icon: Icons.history,
          label: AppText.auditTrail,
          // The check screen (reports plan, T4, Q2): the officer scans the
          // consignment, then taps "Download audit trail" on its result. One
          // person's trail starts from an alert's page instead.
          onTap: () => context.push(AppRoutes.officerCheck),
        ),
      ],
    );
  }
}
