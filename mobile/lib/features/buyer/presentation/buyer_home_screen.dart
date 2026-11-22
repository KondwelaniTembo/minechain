// The buyer's home (plan section 4.2).
// "Check a consignment" is built (consignment check plan), and "Record
// purchase" (buyer purchase plan, T2), "My purchases" and "Send my work"
// (T3), and "Reports" (reports plan, T3). Every tile is built.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/widgets/home_scaffold.dart';
import '../../auth/presentation/home_header.dart';

class BuyerHomeScreen extends ConsumerWidget {
  const BuyerHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          // push(): a task page over the home (reports plan, T3).
          onTap: () => context.push(AppRoutes.buyerReports),
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
