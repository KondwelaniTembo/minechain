// Shown for the moment it takes to read the saved session at start-up. The
// router moves on by itself as soon as the sign-in state is known.

import 'package:flutter/material.dart';

import '../../../core/theme/sizes.dart';
import '../../../core/widgets/mine_chain_logo.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The same logo and name as on the login screen, so the
              // hand-over from splash to login does not change them.
              BrandBlock(
                logoSize: AppSizes.logoLarge,
                nameStyle: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: AppSizes.spaceL),
              const CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}
