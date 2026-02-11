// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:finflow/main.dart';

void main() {
  testWidgets('App builds', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const FinFlowApp());

    // Verify that the app shows the main title.
    expect(find.text('记账'), findsOneWidget);

    // Tap the '+' icon and trigger a frame.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
  }, skip: true);
}

// Build our app and trigger a frame.
// Verify that our counter starts at 0.
// Tap the '+' icon and trigger a frame.
// Verify that our counter has incremented.
