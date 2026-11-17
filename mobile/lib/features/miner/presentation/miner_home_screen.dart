// The miner's home (plan section 4.2). Placeholder tiles for now: each says
// "Coming soon" until its module is built. Above them, the shared header and
// the device key notice (plan M2), shown only when this phone may not sign.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/widgets/coming_soon.dart';
import '../../../core/widgets/home_scaffold.dart';
import '../../auth/presentation/home_header.dart';
import '../../device_key/presentation/device_key_notice.dart';

class MinerHomeScreen extends StatelessWidget {
  const MinerHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void soon() => showComingSoon(context);

    return HomeScaffold(
      title: AppText.minerTitle,
      header: const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [HomeHeader(), DeviceKeyNotice()],
      ),
      // push (not go): the account screen goes on top of this home, so its
      // back arrow and Android's back button return here.
      onAccountPressed: () => context.push(AppRoutes.account),
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
