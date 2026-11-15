// F1's only widget test: the app starts and shows its one screen.

import 'package:flutter_test/flutter_test.dart';

import 'package:minechain/main.dart';

void main() {
  testWidgets('shows the MineChain title and the foundation text',
      (WidgetTester tester) async {
    // pumpWidget builds the app in a test window and draws one frame. No phone
    // or emulator is needed: the test runs on the laptop.
    await tester.pumpWidget(const MineChainApp());

    // findsOneWidget fails the test if the text is missing or appears twice.
    // "MineChain" is the app bar title; MaterialApp's title is not drawn on
    // screen, so it does not count as a second match.
    expect(find.text('MineChain'), findsOneWidget);
    expect(find.text('Foundation build'), findsOneWidget);
  });
}
