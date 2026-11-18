// The administrator's home (plan section 4.2). "Account requests" opens its
// screen (plan A1); the other tiles say "Coming soon" until their module is
// built.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
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
      // push (not go): the account screen goes on top of this home, so its
      // back arrow and Android's back button return here.
      onAccountPressed: () => context.push(AppRoutes.account),
      actions: [
        HomeAction(
          icon: Icons.person_add,
          label: AppText.accountRequests,
          onTap: () => context.push(AppRoutes.adminRequests),
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
