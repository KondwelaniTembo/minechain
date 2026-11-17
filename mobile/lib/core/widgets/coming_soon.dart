// The short "Coming soon" message for buttons whose screens are not built yet.

import 'package:flutter/material.dart';

import '../text/app_text.dart';

/// Shows "Coming soon" at the bottom of the screen.
///
/// hideCurrentSnackBar first, so quick taps do not queue up a line of
/// identical messages.
void showComingSoon(BuildContext context) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text(AppText.comingSoon)));
}
