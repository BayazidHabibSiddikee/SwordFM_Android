import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/screens/network_screen.dart';

void main() {
  group('NetworkScreen UI', () {
    testWidgets('renders with empty profile list', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: NetworkScreen(),
        ),
      );
      expect(find.text('Network Connections'), findsOneWidget);
      expect(find.text('Profiles'), findsOneWidget);
      expect(find.text('No profiles'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('shows select profile message when no connection', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: NetworkScreen(),
        ),
      );
      expect(find.text('Select a profile to connect'), findsOneWidget);
    });
  });
}
