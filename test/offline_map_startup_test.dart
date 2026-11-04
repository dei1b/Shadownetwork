import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:shadownetwork/features/messaging/presentation/pages/home_page.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';

// Keep the home/map configuration real; replace only the native view boundary.
class _MapPlatform extends ml.MapLibrePlatform {
  @override
  Widget buildView(
    Map<String, dynamic> creationParams,
    void Function(int) onPlatformViewCreated,
    Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers,
  ) => const SizedBox.shrink();

  @override
  Future<ml.CameraPosition?> updateMapOptions(
    Map<String, dynamic> options,
  ) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MapController implements ml.MapLibreMapController {
  bool localRequestsEnabled = false;

  @override
  Future<void> forceOnlineMode() async {
    localRequestsEnabled = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home and full map enable loopback requests on every new view', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final originalFactory = ml.MapLibrePlatform.createInstance;
    ml.MapLibrePlatform.createInstance = _MapPlatform.new;
    addTearDown(() => ml.MapLibrePlatform.createInstance = originalFactory);
    const locationChannel = MethodChannel('flutter.baseflow.com/geolocator');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(locationChannel, (_) async => false);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(locationChannel, null);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nearbyPeersProvider.overrideWith((ref) async => []),
          sosMessagesProvider.overrideWith((ref) async => []),
          conversationsProvider.overrideWith((ref) async => []),
          mapTileCacheStoreProvider.overrideWith(
            (ref) async => MemCacheStore(),
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: const HomePage(
            accessProfile: DeviceAccessProfile.unregistered(deviceId: 'test'),
          ),
        ),
      ),
    );
    // The real loopback server binds outside the widget test's fake clock.
    for (var attempt = 0; attempt < 50; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find.byType(ml.MapLibreMap).evaluate().isNotEmpty) break;
    }

    final cardMap = tester.widget<ml.MapLibreMap>(find.byType(ml.MapLibreMap));
    final locate = find.byKey(const ValueKey('locate-me-action'));
    final messages = find.byKey(const ValueKey('messages-action'));
    expect(tester.getSize(locate), tester.getSize(messages));
    expect(tester.getTopLeft(locate).dy, tester.getTopLeft(messages).dy);
    final nearby = find.byKey(const ValueKey('nearby-phones-section'));
    expect(find.text('Nearby phones'), findsOneWidget);
    expect(find.text('SCANNING...'), findsOneWidget);
    expect(
      tester.getBottomLeft(nearby).dy,
      lessThan(tester.getTopLeft(find.byType(ml.MapLibreMap)).dy),
    );
    final sosButton = find.byKey(const ValueKey('open-sos-composer'));
    await tester.ensureVisible(sosButton);
    await tester.pump();
    expect(sosButton.hitTestable(), findsOneWidget);
    expect(
      tester.getTopLeft(sosButton).dy,
      greaterThan(tester.getBottomLeft(find.byType(ml.MapLibreMap)).dy),
    );
    expect(tester.getSize(sosButton).height, greaterThanOrEqualTo(70));
    expect(
      find.descendant(of: sosButton, matching: find.text('SEND SOS MESSAGE')),
      findsOneWidget,
    );
    expect(Uri.parse(cardMap.styleString).host, '127.0.0.1');
    final cardController = _MapController();
    cardMap.onMapCreated!(cardController);
    await tester.pump();
    expect(cardController.localRequestsEnabled, isTrue);

    await tester.tap(find.text('Maps'));
    await tester.pump();
    expect(find.text('MAP'), findsOneWidget);
    expect(find.text('See nearby phones and SOS alerts'), findsOneWidget);
    final fullMap = tester.widget<ml.MapLibreMap>(find.byType(ml.MapLibreMap));
    expect(nearby, findsNothing);
    await tester.ensureVisible(sosButton);
    await tester.pump();
    expect(sosButton.hitTestable(), findsOneWidget);
    expect(
      tester.getTopLeft(sosButton).dy,
      greaterThan(tester.getBottomLeft(find.byType(ml.MapLibreMap)).dy),
    );
    final fullController = _MapController();
    fullMap.onMapCreated!(fullController);
    await tester.pump();
    expect(fullController.localRequestsEnabled, isTrue);

    final homeContext = tester.element(find.byType(HomePage));
    showDialog<void>(
      context: homeContext,
      builder: (_) => const AlertDialog(title: Text('Example dialog')),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Example dialog'), findsNothing);
    expect(find.text('MAP'), findsOneWidget);

    // Revisiting Home still lets Back return to the last visited tab.
    await tester.tap(find.text('Home'));
    await tester.pump();
    await tester.tap(find.text('Home'));
    await tester.pump();
    expect(find.text('MAP'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('MAP'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('MAP'), findsNothing);
    expect(
      tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>)).canPop,
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });
}
