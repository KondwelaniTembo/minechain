// The administrator's home (plan section 4.2). "Account requests" opens its
// screen (plan A1), "Accounts" its list (admin accounts plan, T2) and "GPS
// zones" theirs (GPS zones plan, T2); the other tiles say "Coming soon"
// until their module is built.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/widgets/coming_soon.dart';
import '../../../core/widgets/home_scaffold.dart';
import '../../auth/presentation/home_header.dart';

class AdminHomeScreen extends ConsumerWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void soon() => showComingSoon(context);

    return HomeScaffold(
      title: AppText.adminTitle,
      username: watchUsername(ref),
      header: const HomeHeader(),
      // push (not go): the account screen goes on top of this home, so its
      // back arrow and Android's back button return here.
      // go(), not push(): Account is a place of the navigation bar, and the
      // bar then shows it as chosen (Mobile (37), Q9).
      onAccountPressed: () => context.go(AppRoutes.account),
      actions: [
        HomeAction(
          icon: Icons.person_add,
          label: AppText.accountRequests,
          onTap: () => context.push(AppRoutes.adminRequests),
          primary: true,
        ),
        HomeAction(
          icon: Icons.group,
          label: AppText.accounts,
          onTap: () => context.push(AppRoutes.adminAccounts),
        ),
        HomeAction(
          icon: Icons.map,
          label: AppText.gpsZones,
          onTap: () => context.push(AppRoutes.adminZones),
        ),
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
