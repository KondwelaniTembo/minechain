// The regulatory officer's home (plan section 4.2). Placeholder tiles for now:
// each says "Coming soon" until its module is built.

import 'package:flutter/material.dart';

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
      // The account screen comes in F8.
      onAccountPressed: soon,
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
