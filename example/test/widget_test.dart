// Smoke test for the Chumbaq example app shell.

import 'package:chumbaq_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App shell renders with AppBar title', (tester) async {
    await tester.pumpWidget(const ChumbaqExampleApp());
    expect(find.text('Chumbaq Example'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
