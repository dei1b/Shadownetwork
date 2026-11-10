import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/app/data/first_run_guide_store.dart';
import 'package:shadownetwork/app/presentation/pages/first_run_guide.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';

void main() {
  late DeviceIdentityStore identity;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    identity = DeviceIdentityStore(secretStore: InMemorySecretValueStore());
  });

  test('fresh install remains eligible across restart until finished', () async {
    expect(await FirstRunGuideStore.shouldShow(identity), isTrue);
    await identity.loadOrCreate();
    // The background relay can create an identity before the guide is finished.
    expect(await FirstRunGuideStore.shouldShow(identity), isTrue);
    await FirstRunGuideStore.complete();
    expect(await FirstRunGuideStore.shouldShow(identity), isFalse);
  });

  test('existing phones go straight to the app after updating', () async {
    await identity.loadOrCreate();
    expect(await FirstRunGuideStore.shouldShow(identity), isFalse);
  });

  for (final skip in [false, true]) {
    testWidgets('${skip ? 'skipping' : 'finishing'} the guide opens Home', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 560));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: FirstRunGuideGate(
              shouldShow: Future.value(true),
              child: const Scaffold(body: Text('Home ready')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Send an SOS'), findsOneWidget);
      if (skip) {
        await tester.tap(find.text('Skip'));
      } else {
        for (final title in [
          'Nearby phones pass it on',
          'Use the Panabo offline map',
          'Register with your barangay',
        ]) {
          await tester.ensureVisible(find.text('Next'));
          await tester.tap(find.text('Next'));
          await tester.pumpAndSettle();
          expect(find.text(title), findsOneWidget);
        }
        await tester.ensureVisible(find.text('Get started'));
        await tester.tap(find.text('Get started'));
      }
      await tester.pumpAndSettle();
      expect(find.text('Home ready'), findsOneWidget);
      expect(await FirstRunGuideStore.shouldShow(identity), isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}
