// The buyer's home (plan section 4.2). Placeholder tiles for now: each says
// "Coming soon" until its module is built.
// "Check a consignment" is built (consignment check plan), and "Record
// purchase" (buyer purchase plan, T2), "My purchases" and "Send my work"
// (T3). "Reports" waits for the Reports feature (Sat 21).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/widgets/coming_soon.dart';
import '../../../core/widgets/home_scaffold.dart';
import '../../auth/presentation/home_header.dart';

class BuyerHomeScreen extends ConsumerWidget {
  const BuyerHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void soon() => showComingSoon(context);

    return HomeScaffold(
      title: AppText.buyerTitle,
      username: watchUsername(ref),
      header: const HomeHeader(),
      // push (not go): the account screen goes on top of this home, so its
      // back arrow and Android's back button return here.
      // go(), not push(): Account is a place of the navigation bar, and the
      // bar then shows it as chosen (Mobile (37), Q9).
      onAccountPressed: () => context.go(AppRoutes.account),
      actions: [
        HomeAction(
          icon: Icons.fact_check,
          label: AppText.checkConsignment,
          // push(): a task page over the home, whose back arrow returns here.
          onTap: () => context.push(AppRoutes.buyerCheck),
          primary: true,
        ),
        HomeAction(
          icon: Icons.point_of_sale,
          label: AppText.recordPurchase,
          onTap: () => context.push(AppRoutes.buyerPurchase),
        ),
        HomeAction(
          icon: Icons.receipt_long,
          label: AppText.myPurchases,
          onTap: () => context.push(AppRoutes.buyerPurchases),
        ),
        HomeAction(
          icon: Icons.table_chart,
          label: AppText.reports,
          onTap: soon,
        ),
        HomeAction(
          icon: Icons.cloud_upload,
          label: AppText.sendMyWork,
          onTap: () => context.push(AppRoutes.buyerSync),
        ),
      ],
    );
  }
}
