// The transporter's home (plan section 4.2). Placeholder tiles for now: each
// says "Coming soon" until its module is built.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/widgets/coming_soon.dart';
import '../../../core/widgets/home_scaffold.dart';
import '../../auth/presentation/home_header.dart';

class TransporterHomeScreen extends StatelessWidget {
  const TransporterHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void soon() => showComingSoon(context);

    return HomeScaffold(
      title: AppText.transporterTitle,
      header: const HomeHeader(),
      // push (not go): the account screen goes on top of this home, so its
      // back arrow and Android's back button return here.
      onAccountPressed: () => context.push(AppRoutes.account),
      actions: [
        HomeAction(
          icon: Icons.local_shipping,
          label: AppText.takeCustody,
          onTap: soon,
          primary: true,
        ),
        HomeAction(
          icon: Icons.fact_check,
          label: AppText.checkConsignment,
          onTap: soon,
        ),
        HomeAction(
          icon: Icons.list_alt,
          label: AppText.myHandoffs,
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
