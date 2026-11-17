// The regulatory officer's home (plan section 4.2). Placeholder tiles for now:
// each says "Coming soon" until its module is built.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/widgets/coming_soon.dart';
import '../../../core/widgets/home_scaffold.dart';
import '../../auth/presentation/home_header.dart';

class OfficerHomeScreen extends StatelessWidget {
  const OfficerHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void soon() => showComingSoon(context);

    return HomeScaffold(
      title: AppText.officerTitle,
      header: const HomeHeader(),
      // push (not go): the account screen goes on top of this home, so its
      // back arrow and Android's back button return here.
      onAccountPressed: () => context.push(AppRoutes.account),
      actions: [
        HomeAction(
          icon: Icons.notification_important,
          label: AppText.alerts,
          onTap: soon,
          primary: true,
        ),
        HomeAction(
          icon: Icons.fact_check,
          label: AppText.checkConsignment,
          onTap: soon,
        ),
        HomeAction(
          icon: Icons.table_chart,
          label: AppText.reports,
          onTap: soon,
        ),
        HomeAction(
          icon: Icons.history,
          label: AppText.auditTrail,
          onTap: soon,
        ),
      ],
    );
  }
}
