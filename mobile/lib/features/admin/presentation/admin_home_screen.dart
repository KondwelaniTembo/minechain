// The administrator's home (plan section 4.2). Placeholder tiles for now: each
// says "Coming soon" until its module is built.

import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../../../core/widgets/coming_soon.dart';
import '../../../core/widgets/home_scaffold.dart';
import '../../auth/presentation/home_header.dart';

class AdminHomeScreen extends StatelessWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void soon() => showComingSoon(context);

    return HomeScaffold(
      title: AppText.adminTitle,
      header: const HomeHeader(),
      // The account screen comes in F8.
      onAccountPressed: soon,
      actions: [
        HomeAction(
          icon: Icons.person_add,
          label: AppText.accountRequests,
          onTap: soon,
          primary: true,
        ),
        HomeAction(icon: Icons.group, label: AppText.accounts, onTap: soon),
        HomeAction(icon: Icons.map, label: AppText.gpsZones, onTap: soon),
        HomeAction(icon: Icons.link, label: AppText.anchoring, onTap: soon),
        HomeAction(
          icon: Icons.table_chart,
          label: AppText.reports,
          onTap: soon,
        ),
      ],
    );
  }
}
