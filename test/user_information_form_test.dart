import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/security/data/services/user_information_store.dart';
import 'package:shadownetwork/features/trust/presentation/widgets/user_information_form.dart';

void main() {
  testWidgets('phone information validates, saves offline and reloads', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    Widget page() => const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: UserInformationForm())),
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save user information'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your full name.'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Full name'),
      'Maria Santos',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Phone number'),
      '+63 912 345 6789',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Address'),
      'Purok 2, Panabo City',
    );
    await tester.ensureVisible(find.text('Save user information'));
    await tester.tap(find.text('Save user information'));
    await tester.pumpAndSettle();
    final saved = await UserInformationStore().load();
    expect(saved!.fullName, 'Maria Santos');
    expect(saved.phoneNumber, '+63 912 345 6789');
    expect(saved.address, 'Purok 2, Panabo City');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('Maria Santos'), findsOneWidget);
    expect(find.text('Purok 2, Panabo City'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
