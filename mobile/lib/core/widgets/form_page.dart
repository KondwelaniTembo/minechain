// The frame of a signed-out form page (register, activate): a top bar with a
// back arrow to the login screen, the server status, then the form, all
// scrolling.
//
// Why it scrolls: when the keyboard opens, Scaffold shrinks the body to the
// space above it (resizeToAvoidBottomInset, on by default). A scroll view
// inside can then still reach every field and the button; without one, the
// form would overflow on a 5-inch phone in landscape.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../router/routes.dart';
import '../theme/sizes.dart';
import 'server_status_banner.dart';

class FormPage extends StatelessWidget {
  const FormPage({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Explicit, so the arrow is there even if this page was opened with
        // go() and has no login screen underneath.
        leading: BackButton(onPressed: () => backToLogin(context)),
        title: Text(title),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSizes.spaceL),
            child: ConstrainedBox(
              // A comfortable width on a turned phone, like the login form.
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [const ServerStatusBanner(), ...children],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Back to the login screen: pop if it is underneath (the normal case,
/// because the login screen opens these pages with push), otherwise go there.
void backToLogin(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(AppRoutes.login);
  }
}
