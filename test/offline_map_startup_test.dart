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
        child: const MaterialApp(
          home: HomePage(
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
    expect(Uri.parse(cardMap.styleString).host, '127.0.0.1');
    final cardController = _MapController();
    cardMap.onMapCreated!(cardController);
    await tester.pump();
    expect(cardController.localRequestsEnabled, isTrue);

    await tester.tap(find.text('Maps'));
    await tester.pump();
    final fullMap = tester.widget<ml.MapLibreMap>(find.byType(ml.MapLibreMap));
    final fullController = _MapController();
    fullMap.onMapCreated!(fullController);
    await tester.pump();
    expect(fullController.localRequestsEnabled, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });
}
