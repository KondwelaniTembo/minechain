// Shown for the moment it takes to read the saved session at start-up. The
// router moves on by itself as soon as the sign-in state is known.

import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';

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
              Text(
                AppText.appTitle,
                // The same look as the name on the login screen, so the
                // hand-over from splash to login does not change it.
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.primary,
                ),
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
