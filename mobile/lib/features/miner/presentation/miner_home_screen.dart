// The miner's home (plan section 4.2). Placeholder tiles for now: each says
// "Coming soon" until its module is built.

import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../../../core/widgets/coming_soon.dart';
import '../../../core/widgets/home_scaffold.dart';
import '../../auth/presentation/home_header.dart';

class MinerHomeScreen extends StatelessWidget {
  const MinerHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void soon() => showComingSoon(context);

    return HomeScaffold(
      title: AppText.minerTitle,
      header: const HomeHeader(),
      // The account screen comes in F8.
      onAccountPressed: soon,
      actions: [
        HomeAction(
          icon: Icons.qr_code_scanner,
          label: AppText.registerConsignment,
          onTap: soon,
          primary: true,
        ),
        HomeAction(
          icon: Icons.inventory_2,
          label: AppText.myConsignments,
          onTap: soon,
        ),
        HomeAction(
          icon: Icons.cloud_upload,
          label: AppText.sendMyWork,
          onTap: soon,
        ),
      ],
    );
  }
}
