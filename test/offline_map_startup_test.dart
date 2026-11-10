import 'dart:async';

import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_moderation_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/messaging/presentation/pages/home_page.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/relay_runtime_provider.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_trust_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  Future<bool?> moveCamera(ml.CameraUpdate cameraUpdate) async => true;

  @override
  Future<void> forceOnlineMode() async {
    localRequestsEnabled = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopRelayRuntime extends RelayRuntimeController {
  @override
  Future<void> syncNow({bool force = true}) async {}
}

class _ScannedRelayRuntime extends RelayRuntimeController {
  @override
  RelayRuntimeState build() => RelayRuntimeState(
    isRunning: true,
    isSyncing: false,
    permissionsGranted: true,
    discoveredPeers: 3,
    connectedPeers: 0,
    lastUpdated: DateTime.utc(2026, 11, 4),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final header = find.byKey(const ValueKey('mobile-tab-header'));
  Finder headerText(String label) =>
      find.descendant(of: header, matching: find.text(label));

  testWidgets('responder alerts distinguish outgoing SOS from received SOS', (
    tester,
  ) async {
    final originalFactory = ml.MapLibrePlatform.createInstance;
    ml.MapLibrePlatform.createInstance = _MapPlatform.new;
    addTearDown(() => ml.MapLibrePlatform.createInstance = originalFactory);
    const channel = MethodChannel('flutter.baseflow.com/geolocator');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final messages = Completer<List<SosMessage>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nearbyPeersProvider.overrideWith((ref) async => []),
          sosMessagesProvider.overrideWith((ref) => messages.future),
          conversationsProvider.overrideWith((ref) async => []),
          relayRuntimeProvider.overrideWith(_ScannedRelayRuntime.new),
          mapTileCacheStoreProvider.overrideWith(
            (ref) async => MemCacheStore(),
          ),
        ],
        child: const MaterialApp(
          home: HomePage(
            accessProfile: DeviceAccessProfile(
              level: DeviceAccessLevel.responder,
              deviceId: 'responder',
              ownerName: 'Registered Responder',
            ),
          ),
        ),
      ),
    );
    expect(headerText('Responder dashboard'), findsOneWidget);
    expect(find.text('Checking for SOS alerts…'), findsOneWidget);
    final normal = SosMessage(
      id: 'emergency',
      sender: const Peer(
        id: 'resident',
        name: 'Resident',
        type: PeerType.civilian,
        isConnected: false,
      ),
      body: 'Need medical assistance.',
      category: Category.medical,
      status: MessageStatus.received,
      createdAt: DateTime.now(),
    );
    const local = Peer(
      id: 'RESPONDER',
      name: 'Phone model',
      type: PeerType.responder,
      isConnected: false,
    );
    messages.complete([
      normal,
      normal.copyWith(
        id: 'own',
        sender: local,
        status: MessageStatus.queued,
        body: 'My outgoing SOS.',
      ),
      normal.copyWith(id: 'received-local-id', sender: local),
      normal.copyWith(id: 'request', category: Category.water),
      normal.copyWith(id: 'update', category: Category.information),
      normal.copyWith(id: 'revoked', trustStatus: DeviceTrustStatus.revoked),
      normal.copyWith(
        id: 'spam',
        moderationStatus: MessageModerationStatus.spam,
      ),
    ]);
    await tester.pump();
    expect(find.text('3 SOS alerts on this phone'), findsOneWidget);
    await tester.tap(find.text('Open SOS alerts'));
    await tester.pump();
    expect(headerText('Alerts'), findsOneWidget);
    expect(find.byKey(const ValueKey('sos-card-emergency')), findsOneWidget);
    for (final id in ['request', 'update', 'revoked', 'spam']) {
      expect(find.byKey(ValueKey('sos-card-$id')), findsNothing);
    }
    final ownCard = find.byKey(const ValueKey('sos-card-own'));
    await tester.ensureVisible(ownCard);
    await tester.pump();
    expect(
      find.descendant(
        of: ownCard,
        matching: find.textContaining('Registered Responder (you)'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: ownCard, matching: find.text('UNVERIFIED')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sos-card-received-local-id')),
        matching: find.text('UNVERIFIED'),
      ),
      findsOneWidget,
    );
    await tester.tap(ownCard);
    await tester.pumpAndSettle();
    expect(find.text('SOS details'), findsOneWidget);
    expect(find.text('Message sender'), findsNothing);
    expect(find.text('Created on this phone'), findsOneWidget);
    expect(find.text('Saved on this phone · Delivery pending'), findsWidgets);
    await tester.tap(find.byTooltip('Close SOS details'));
    await tester.pumpAndSettle();

    final incomingCard = find.byKey(const ValueKey('sos-card-emergency'));
    await tester.ensureVisible(incomingCard);
    await tester.pump();
    await tester.tap(incomingCard);
    await tester.pumpAndSettle();
    expect(find.text('Message sender'), findsOneWidget);
    await tester.tap(find.byTooltip('Close SOS details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SOS Map'));
    await tester.pump();
    expect(headerText('SOS Map'), findsOneWidget);
    await tester.tap(find.text('Network'));
    await tester.pump();
    expect(headerText('Network'), findsOneWidget);
    expect(headerText('3 phones detected in the latest scan'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });

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
    final cardState = tester.state(find.byType(ml.MapLibreMap));
    expect(headerText('ShadowNetwork'), findsOneWidget);
    expect(headerText('Registration available'), findsOneWidget);
    final locate = find.byKey(const ValueKey('locate-me-action'));
    final messages = find.byKey(const ValueKey('messages-action'));
    expect(tester.getSize(locate), tester.getSize(messages));
    expect(tester.getTopLeft(locate).dy, tester.getTopLeft(messages).dy);
    final nearby = find.byKey(const ValueKey('nearby-phones-section'));
    expect(find.text('View all'), findsNothing);
    expect(find.text('Nearby phones'), findsOneWidget);
    expect(find.text('Scanning…'), findsOneWidget);
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
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('See nearby phones and SOS alerts'), findsOneWidget);
    expect(headerText('Panabo offline'), findsOneWidget);
    final fullMap = tester.widget<ml.MapLibreMap>(find.byType(ml.MapLibreMap));
    final fullState = tester.state(find.byType(ml.MapLibreMap));
    expect(find.byType(ml.MapLibreMap, skipOffstage: false), findsNWidgets(2));
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
    expect(find.text('Map'), findsOneWidget);

    // Revisiting Home still lets Back return to the last visited tab.
    await tester.tap(find.text('Home'));
    await tester.pump();
    expect(
      identical(tester.state(find.byType(ml.MapLibreMap)), cardState),
      isTrue,
    );
    await tester.tap(find.text('Home'));
    await tester.pump();
    expect(find.text('Map'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Map'), findsOneWidget);
    expect(
      identical(tester.state(find.byType(ml.MapLibreMap)), fullState),
      isTrue,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Map'), findsNothing);
    expect(
      tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>)).canPop,
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });

  testWidgets('SOS can broadcast with unreadable approval and keeps shown GPS', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final originalFactory = ml.MapLibrePlatform.createInstance;
    ml.MapLibrePlatform.createInstance = _MapPlatform.new;
    addTearDown(() => ml.MapLibrePlatform.createInstance = originalFactory);
    SharedPreferences.setMockInitialValues({
      'shadow_network_verified_trust_state_v2': '{broken-json',
    });
    addTearDown(() => SharedPreferences.setMockInitialValues({}));

    var gpsEnabled = false;
    const latitude = 7.3026;
    const longitude = 125.6888;
    const locationChannel = MethodChannel('flutter.baseflow.com/geolocator');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(locationChannel, (call) async {
      return switch (call.method) {
        'isLocationServiceEnabled' => gpsEnabled,
        'checkPermission' => 2, // While in use.
        'getCurrentPosition' => {'latitude': latitude, 'longitude': longitude},
        _ => null,
      };
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(locationChannel, null),
    );

    SosMessage? saved;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nearbyPeersProvider.overrideWith(
            (ref) async => List.generate(
              8,
              (index) => Peer(
                id: 'peer-$index',
                name: 'Nearby phone $index',
                type: PeerType.civilian,
                isConnected: false,
              ),
            ),
          ),
          sosMessagesProvider.overrideWith((ref) async => [?saved]),
          conversationsProvider.overrideWith((ref) async => []),
          mapTileCacheStoreProvider.overrideWith(
            (ref) async => MemCacheStore(),
          ),
          relayRuntimeProvider.overrideWith(_NoopRelayRuntime.new),
          localPeerProvider.overrideWith(
            (ref) async => const Peer(
              id: 'test',
              name: 'Test resident',
              type: PeerType.civilian,
              isConnected: false,
            ),
          ),
          saveSosMessageProvider.overrideWithValue((message) async {
            saved = message;
          }),
        ],
        child: const MaterialApp(
          home: HomePage(
            accessProfile: DeviceAccessProfile.unregistered(deviceId: 'test'),
          ),
        ),
      ),
    );
    await tester.pump();
    final open = find.byKey(const ValueKey('open-sos-composer'));
    final nearby = find.byKey(const ValueKey('nearby-phones-section'));
    expect(find.text('Send SOS'), findsNothing);
    expect(
      find.descendant(of: nearby, matching: find.text('Nearby phone 0')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: nearby, matching: find.text('Nearby phone 1')),
      findsOneWidget,
    );
    expect(find.text('Nearby phone 7'), findsNothing);
    expect(find.text('CONNECT'), findsNothing);

    // A previously selected directory filter must not hide phones from View all.
    await tester.tap(find.text('Nearby'));
    await tester.pump();
    await tester.tap(find.text('Connected').last);
    await tester.pump();
    expect(find.text('No peers match this filter yet.'), findsOneWidget);
    await tester.tap(find.text('Home'));
    await tester.pump();
    final viewAll = find.text('View all');
    expect(viewAll.hitTestable(), findsOneWidget);
    await tester.tap(viewAll);
    await tester.pump();
    expect(headerText('Nearby phones'), findsOneWidget);
    expect(headerText('Waiting for a nearby scan'), findsOneWidget);
    expect(find.text('Nearby phone 7'), findsOneWidget);
    expect(find.text('CONNECT'), findsWidgets);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(nearby, findsOneWidget);
    expect(open.hitTestable(), findsOneWidget);
    await tester.tap(open);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));

    expect(
      find.text(
        'Couldn’t load approved recipients. You can still broadcast this SOS.',
      ),
      findsOneWidget,
    );
    expect(find.text('Broadcast'), findsOneWidget);
    expect(find.text('No GPS location attached'), findsOneWidget);

    final update = find.text('Update');
    gpsEnabled = true;
    await tester.ensureVisible(update);
    await tester.tap(update);
    await tester.pump();
    expect(find.text('7.3026° N, 125.6888° E'), findsOneWidget);

    gpsEnabled = false;
    await tester.tap(update);
    await tester.pump();
    expect(
      find.text(
        'Couldn’t update your location. The last location shown will be attached.',
      ),
      findsOneWidget,
    );
    expect(find.text('7.3026° N, 125.6888° E'), findsOneWidget);

    final details = find.byType(TextField);
    await tester.ensureVisible(details);
    await tester.enterText(details, 'Need help near the school.');
    final send = find.text('SEND SOS');
    await tester.ensureVisible(send);
    await tester.tap(send);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();

    expect(saved?.body, 'Need help near the school.');
    expect(saved?.latitude, latitude);
    expect(saved?.longitude, longitude);
    expect(saved?.status, MessageStatus.queued);
    expect(saved?.recipient, isNull);
    expect(saved?.isEncrypted, isFalse);
    expect(find.text('SOS Created'), findsOneWidget);

    final home = tester.element(find.byType(HomePage));
    ProviderScope.containerOf(
      home,
      listen: false,
    ).invalidate(sosMessagesProvider);
    await tester.tap(find.text('DONE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.tap(find.text('Messages'));
    await tester.pump();
    expect(headerText('Messages'), findsOneWidget);
    expect(headerText('Your SOS updates and conversations'), findsOneWidget);
    expect(find.text('Saved on this phone · Delivery pending'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });
}
