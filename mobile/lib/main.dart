// The MineChain app, F1: one plain screen to prove the Android settings work.
// Riverpod (F2) and routing (F7) come later; nothing here is meant to last.

// material.dart gives us Google's Material Design widgets: buttons, app bars,
// text styles and themes. Almost every Flutter screen imports it.
import 'package:flutter/material.dart';

// main() is where every Dart program starts. Android launches the app, the
// Flutter engine starts, and then it calls this function.
void main() {
  // runApp() takes a widget and makes it the root of the whole screen. From then
  // on Flutter draws that widget and everything inside it, and redraws when
  // something changes.
  runApp(const MineChainApp());
}

// In Flutter everything on screen is a widget, and widgets are nested inside each
// other like boxes. A StatelessWidget has no data of its own that changes: it
// draws the same thing each time. That is all this first screen needs.
class MineChainApp extends StatelessWidget {
  // `const` lets Flutter build this widget once and reuse it, because nothing
  // about it can change. `super.key` passes an optional identity to the parent
  // class; Flutter uses keys to tell widgets apart when a list changes.
  const MineChainApp({super.key});

  // build() describes what this widget looks like. Flutter calls it whenever it
  // needs to draw the widget, so it should only describe, never do slow work.
  @override
  Widget build(BuildContext context) {
    // MaterialApp sets up the things every screen shares: the theme (colours and
    // fonts), the app's title, text direction, and the navigator that moves
    // between screens. There is normally exactly one, at the top.
    return MaterialApp(
      // The title Android shows in the recent-apps list. The name under the
      // launcher icon comes from android:label in AndroidManifest.xml instead.
      title: 'MineChain',
      // Hides the red "DEBUG" ribbon in the corner of debug builds.
      debugShowCheckedModeBanner: false,
      // ThemeData holds the app's look. ColorScheme.fromSeed builds a whole,
      // matching set of Material 3 colours from one colour. Material 3 is
      // Flutter's default design today; useMaterial3 just says so plainly.
      // The real theme comes in F2.
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      // home is the first screen MaterialApp shows.
      home: const FoundationScreen(),
    );
  }
}

// The one screen of F1.
class FoundationScreen extends StatelessWidget {
  const FoundationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Scaffold is the basic layout of one Material screen. It has named slots,
    // such as appBar (the bar at the top), body (the main area), and later a
    // bottom navigation bar or a floating button, and it places each correctly.
    return Scaffold(
      // AppBar is the bar across the top of the screen, holding the screen's
      // title and, later, buttons such as "Account".
      appBar: AppBar(title: const Text('MineChain')),
      // Center places its one child in the middle of the space it is given;
      // here that is the whole body, below the app bar.
      body: const Center(child: Text('Foundation build')),
    );
  }
}
