import 'dart:async';

import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:shadownetwork/app/presentation/pages/settings_page.dart';
import 'package:shadownetwork/core/widgets/native_activity_scope.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/chat_message.dart';
import 'package:shadownetwork/features/messaging/domain/entities/conversation.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_moderation_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_location_share.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/messaging/presentation/pages/home_page.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/peer_location_providers.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/relay_runtime_provider.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_trust_status.dart';
import 'package:shadownetwork/features/trust/presentation/providers/device_access_provider.dart';
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
  final layerVisibility = <String, bool>{};

  @override
  Future<bool?> moveCamera(ml.CameraUpdate cameraUpdate) async => true;

  @override
  Future<void> forceOnlineMode() async {
    localRequestsEnabled = true;
  }

  @override
  Future<void> setLayerVisibility(String layerId, bool visible) async {
    layerVisibility[layerId] = visible;
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

  for (final level in [
    DeviceAccessLevel.civilian,
    DeviceAccessLevel.responder,
  ]) {
    testWidgets('${level.name} archives and restores their own SOS', (
      tester,
    ) async {
      final originalFactory = ml.MapLibrePlatform.createInstance;
      ml.MapLibrePlatform.createInstance = _MapPlatform.new;
      addTearDown(() => ml.MapLibrePlatform.createInstance = originalFactory);
      const channel = MethodChannel('flutter.baseflow.com/geolocator');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => false);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final archivedState = StateProvider<bool>((ref) => false);
      final own = SosMessage(
        id: 'own',
        sender: const Peer(
          id: 'resident',
          name: 'Resident',
          type: PeerType.civilian,
          isConnected: false,
        ),
        body: 'My outgoing SOS.',
        category: Category.medical,
        status: MessageStatus.queued,
        createdAt: DateTime.now(),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            nearbyPeersProvider.overrideWith((ref) async => []),
            sosMessagesProvider.overrideWith(
              (ref) async => [
                own.copyWith(
                  archivedAt: ref.watch(archivedState) ? DateTime.now() : null,
                ),
              ],
            ),
            setSosArchivedProvider.overrideWith((ref) {
              return (id, {required archived}) async {
                expect(id, own.id);
                ref.read(archivedState.notifier).state = archived;
                return true;
              };
            }),
            conversationsProvider.overrideWith(
              (ref) async => [
                Conversation(
                  id: 'old-chat',
                  localPeerId: 'resident',
                  remotePeer: const Peer(
                    id: 'classmate',
                    name: 'Classmate',
                    type: PeerType.civilian,
                    isConnected: false,
                  ),
                  createdAt: DateTime.utc(2026, 11, 1),
                  updatedAt: DateTime.utc(2026, 11, 1),
                  unreadCount: 0,
                  latestBody: 'Old private chat',
                ),
              ],
            ),
            relayRuntimeProvider.overrideWith(_NoopRelayRuntime.new),
            mapTileCacheStoreProvider.overrideWith(
              (ref) async => MemCacheStore(),
            ),
          ],
          child: MaterialApp(
            home: HomePage(
              accessProfile: DeviceAccessProfile(
                level: level,
                deviceId: 'resident',
                ownerName: 'Resident',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .text(level == DeviceAccessLevel.civilian ? 'Messages' : 'Alerts')
            .last,
      );
      await tester.pumpAndSettle();
      if (level == DeviceAccessLevel.responder) {
        expect(find.text('No active incoming SOS alerts.'), findsOneWidget);
        final all = find.text('All Messages');
        await tester.ensureVisible(all);
        await tester.tap(all);
        await tester.pumpAndSettle();
      }
      final card = find.byKey(const ValueKey('sos-card-own'));
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.text('Mark responded'), findsNothing);
      await tester.tap(find.text('Archive SOS'));
      await tester.pumpAndSettle();
      expect(card, findsNothing);
      expect(find.text('Old private chat'), findsOneWidget);
      expect(find.text('No messages in this view.'), findsNothing);
      final filter = find.text('Archive');
      await tester.ensureVisible(filter);
      await tester.tap(filter);
      await tester.pumpAndSettle();
      expect(card, findsOneWidget);
      await tester.tap(card);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore SOS'));
      await tester.pumpAndSettle();
      expect(card, findsNothing);
      final allMessages = find.text('All Messages');
      await tester.ensureVisible(allMessages);
      await tester.tap(allMessages);
      await tester.pumpAndSettle();
      expect(card, findsOneWidget);
      if (level == DeviceAccessLevel.responder) {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        addTearDown(tester.view.resetPhysicalSize);
        for (final size in [const Size(360, 740), const Size(740, 360)]) {
          tester.view.physicalSize = size * tester.view.devicePixelRatio;
          await tester.pumpAndSettle();
          expect(find.text('Dashboard'), findsOneWidget);
          final dashboard = find.byKey(const ValueKey('mobile-nav-0'));
          expect(dashboard.hitTestable(), findsOneWidget);
          expect(tester.getSize(dashboard).height, greaterThanOrEqualTo(48));
          expect(tester.takeException(), isNull);
        }
      }
    });
  }

  testWidgets('responder alerts distinguish outgoing SOS from received SOS', (
    tester,
  ) async {
    final originalFactory = ml.MapLibrePlatform.createInstance;
    ml.MapLibrePlatform.createInstance = _MapPlatform.new;
    addTearDown(() => ml.MapLibrePlatform.createInstance = originalFactory);
    const channel = MethodChannel('flutter.baseflow.com/geolocator');
    final messenger = tester.binding.defaultBinaryMessenger;
    final position = Completer<Map<String, double>>();
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => switch (call.method) {
        'isLocationServiceEnabled' => true,
        'checkPermission' => 2,
        'getCurrentPosition' => position.future,
        _ => null,
      },
    );
    const updates = MethodChannel('flutter.baseflow.com/geolocator_updates');
    messenger.setMockMethodCallHandler(updates, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(updates, null));
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final messages = Completer<List<SosMessage>>();
    final archived = StateProvider<bool>((ref) => false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nearbyPeersProvider.overrideWith((ref) async => []),
          sosMessagesProvider.overrideWith((ref) async {
            final isArchived = ref.watch(archived);
            final items = await messages.future;
            return [
              for (final message in items)
                if (message.id == 'emergency' && isArchived)
                  message.copyWith(respondedAt: DateTime.utc(2026, 11, 11))
                else
                  message,
            ];
          }),
          setSosRespondedProvider.overrideWith((ref) {
            return (id, {required responded}) async {
              expect(id, 'emergency');
              ref.read(archived.notifier).state = responded;
              return true;
            };
          }),
          conversationsProvider.overrideWith(
            (ref) async => [
              Conversation(
                id: 'old-chat',
                localPeerId: 'responder',
                remotePeer: const Peer(
                  id: 'old-contact',
                  name: 'Old contact',
                  type: PeerType.civilian,
                  isConnected: false,
                ),
                createdAt: DateTime.utc(2026, 11, 1),
                updatedAt: DateTime.utc(2026, 11, 1),
                unreadCount: 0,
                latestBody: 'Old private chat',
              ),
            ],
          ),
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
    expect(headerText('Campus responder dashboard'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsNothing);
    expect(find.text('VALIDATION TEST'), findsNothing);
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
      latitude: 7.3139,
      longitude: 125.6705,
    );
    const local = Peer(
      id: 'RESPONDER',
      name: 'Phone model',
      type: PeerType.responder,
      isConnected: false,
    );
    messages.complete([
      normal.copyWith(
        id: 'received-local-id',
        sender: local,
        receivedAt: normal.createdAt.subtract(const Duration(minutes: 5)),
      ),
      normal.copyWith(receivedAt: normal.createdAt),
      normal.copyWith(id: 'local-replay', sender: local),
      normal.copyWith(
        id: 'own',
        sender: local,
        status: MessageStatus.queued,
        body: 'My outgoing SOS.',
        moderationStatus: MessageModerationStatus.spam,
        moderationReason: 'jaccard_similarity',
      ),
      normal.copyWith(id: 'request', category: Category.water),
      normal.copyWith(id: 'update', category: Category.information),
      normal.copyWith(id: 'revoked', trustStatus: DeviceTrustStatus.revoked),
      normal.copyWith(
        id: 'spam',
        moderationStatus: MessageModerationStatus.spam,
      ),
    ]);
    await tester.pump();
    expect(find.text('2 SOS alerts on this phone'), findsOneWidget);
    await tester.tap(find.text('Open SOS alerts'));
    await tester.pump();
    expect(headerText('Alerts'), findsOneWidget);
    expect(find.byKey(const ValueKey('sos-card-emergency')), findsOneWidget);
    for (final id in ['request', 'update', 'revoked', 'spam', 'local-replay']) {
      expect(find.byKey(ValueKey('sos-card-$id')), findsNothing);
    }
    final incomingCard = find.byKey(const ValueKey('sos-card-emergency'));
    final olderIncomingCard = find.byKey(
      const ValueKey('sos-card-received-local-id'),
    );
    expect(
      tester.getTopLeft(incomingCard).dy,
      lessThan(tester.getTopLeft(olderIncomingCard).dy),
    );
    expect(find.text('Old private chat'), findsNothing);
    final ownCard = find.byKey(const ValueKey('sos-card-own'));
    expect(ownCard, findsNothing);
    await tester.tap(find.text('Chats'));
    await tester.pump();
    expect(find.text('Old private chat'), findsOneWidget);
    expect(incomingCard, findsNothing);
    await tester.tap(find.text('Dashboard'));
    await tester.pump();
    await tester.tap(find.text('Alerts'));
    await tester.pump();
    expect(incomingCard, findsOneWidget);
    final all = find.text('All Messages');
    await tester.ensureVisible(all);
    await tester.tap(all);
    await tester.pump();
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
    expect(find.text('Mark responded'), findsNothing);
    await tester.ensureVisible(find.text('Delivery details'));
    await tester.tap(find.text('Delivery details'));
    await tester.pumpAndSettle();
    expect(find.text('Created on this phone'), findsOneWidget);
    expect(find.text('Moderation'), findsNothing);
    expect(find.text('Saved on this phone · Delivery pending'), findsWidgets);
    await tester.tap(find.byTooltip('Close SOS details'));
    await tester.pumpAndSettle();

    final active = find.text('Active SOS');
    await tester.ensureVisible(active);
    await tester.tap(active);
    await tester.pump();
    await tester.ensureVisible(incomingCard);
    await tester.pump();
    await tester.tap(incomingCard);
    await tester.pumpAndSettle();
    expect(find.text('Message sender'), findsOneWidget);
    await tester.tap(find.text('Show on map'));
    await tester.pumpAndSettle();
    expect(find.text('SOS details'), findsNothing);
    expect(headerText('SOS Map'), findsOneWidget);
    for (var attempt = 0; attempt < 50; attempt++) {
      if (find.byType(ml.MapLibreMap).evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    position.complete({'latitude': 7.3026, 'longitude': 125.6888});
    await tester.pumpAndSettle();
    final map = tester.widget<ml.MapLibreMap>(find.byType(ml.MapLibreMap));
    expect(map.initialCameraPosition?.target.latitude, normal.latitude);
    expect(map.initialCameraPosition?.target.longitude, normal.longitude);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.ensureVisible(incomingCard);
    await tester.tap(incomingCard);
    await tester.pumpAndSettle();
    expect(find.text('Mark responded'), findsOneWidget);
    await tester.tap(find.text('Mark responded'));
    await tester.pumpAndSettle();
    expect(incomingCard, findsNothing);
    final archiveFilter = find.text('Archive');
    await tester.ensureVisible(archiveFilter);
    await tester.tap(archiveFilter);
    await tester.pumpAndSettle();
    expect(incomingCard, findsOneWidget);
    await tester.ensureVisible(incomingCard);
    await tester.tap(incomingCard);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore alert'));
    await tester.pumpAndSettle();
    expect(incomingCard, findsNothing);
    expect(find.text('SOS restored to active alerts.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
    final spamFilter = find.text('Spam');
    await tester.ensureVisible(spamFilter);
    await tester.pumpAndSettle();
    await tester.tap(spamFilter);
    await tester.pump();
    expect(ownCard, findsNothing);
    expect(find.byKey(const ValueKey('sos-card-spam')), findsOneWidget);

    await tester.tap(find.text('SOS Map'));
    await tester.pump();
    expect(headerText('SOS Map'), findsOneWidget);
    await tester.tap(find.text('Network'));
    await tester.pump();
    expect(headerText('Network'), findsOneWidget);
    expect(headerText('No phones seen recently'), findsOneWidget);
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(headerText('Profile'), findsOneWidget);
    expect(find.text('This phone’s offline access'), findsOneWidget);
    expect(find.textContaining('Campus responder'), findsOneWidget);
    expect(find.text('Active on this phone'), findsNothing);
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
    final activity = ValueNotifier(0);
    addTearDown(activity.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceAccessProfileProvider.overrideWith(
            (ref) async =>
                const DeviceAccessProfile.unregistered(deviceId: 'test'),
          ),
          nearbyPeersProvider.overrideWith((ref) async => []),
          sosMessagesProvider.overrideWith((ref) async => []),
          conversationsProvider.overrideWith((ref) async => []),
          mapTileCacheStoreProvider.overrideWith(
            (ref) async => MemCacheStore(),
          ),
        ],
        child: MaterialApp(
          routes: {
            '/settings': (_) => const SettingsPage(),
            '/trust-bundle': (_) =>
                const Scaffold(body: Text('Backup QR route')),
          },
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: ValueListenableBuilder<int>(
            valueListenable: activity,
            builder: (_, generation, child) =>
                NativeActivityScope(generation: generation, child: child!),
            child: const HomePage(
              accessProfile: DeviceAccessProfile.unregistered(deviceId: 'test'),
            ),
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
    expect(find.byIcon(Icons.location_pin), findsNothing);
    expect(find.text('Showing my location'), findsNothing);
    final locate = find.byKey(const ValueKey('locate-me-action'));
    final messages = find.byKey(const ValueKey('messages-action'));
    expect(tester.getSize(locate), tester.getSize(messages));
    expect(tester.getTopLeft(locate).dy, tester.getTopLeft(messages).dy);
    final nearby = find.byKey(const ValueKey('nearby-phones-section'));
    expect(find.text('View all'), findsNothing);
    expect(find.text('Nearby phones'), findsOneWidget);
    expect(find.text('Starting…'), findsOneWidget);
    expect(
      tester.getBottomLeft(nearby).dy + 14,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(ml.MapLibreMap)).dy),
    );
    expect(
      tester.getTopLeft(find.text('REGISTER THIS PHONE')).dy,
      greaterThan(tester.getBottomLeft(locate).dy),
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
    expect(headerText('Offline map'), findsOneWidget);
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
    fullMap.onStyleLoadedCallback!();
    await tester.pump();
    expect(fullController.localRequestsEnabled, isTrue);
    for (final label in ['Zoom in', 'Zoom out', 'Reset map north']) {
      final control = find.byTooltip(label);
      expect(control.hitTestable(), findsOneWidget);
      expect(tester.getSize(control), const Size(48, 48));
    }
    expect(find.text('Go to DNSC'), findsOneWidget);
    await tester.tap(find.byTooltip('Map layers and markers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DNSC campus overlay'));
    await tester.pumpAndSettle();
    expect(fullController.layerVisibility['dnsc-campus-overlay'], isFalse);
    await tester.tap(find.byTooltip('Map layers and markers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DNSC campus overlay'));
    await tester.pumpAndSettle();
    expect(fullController.layerVisibility['dnsc-campus-overlay'], isTrue);

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

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(headerText('Profile'), findsOneWidget);
    expect(find.textContaining('Phone approval needed'), findsOneWidget);
    expect(find.text('Phone registration'), findsNothing);
    await tester.ensureVisible(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('DNSC registration'), findsNothing);
    expect(find.text('Backup registration'), findsNothing);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Backup registration'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backup registration'));
    await tester.pumpAndSettle();
    expect(find.text('Backup QR route'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Map'), findsOneWidget);

    // Revisiting Home still lets Back return to the last visited tab.
    await tester.tap(find.text('Home'));
    await tester.pump();
    expect(find.textContaining('Open Profile, then Settings'), findsOneWidget);
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

    const lastCamera = ml.CameraPosition(
      target: ml.LatLng(7.31, 125.69),
      zoom: 15,
    );
    cardMap.onCameraMove!(lastCamera);
    await tester.pump();
    activity.value++;
    await tester.pump();
    expect(find.text('Map'), findsNothing);
    expect(tester.state(find.byType(ml.MapLibreMap)), isNot(same(cardState)));
    final newCard = tester.widget<ml.MapLibreMap>(find.byType(ml.MapLibreMap));
    expect(newCard.initialCameraPosition?.target, lastCamera.target);
    expect(newCard.initialCameraPosition?.zoom, lastCamera.zoom);
    final staleController = _MapController();
    cardMap.onMapCreated!(staleController);
    expect(staleController.localRequestsEnabled, isFalse);
    final newCardController = _MapController();
    newCard.onMapCreated!(newCardController);
    expect(newCardController.localRequestsEnabled, isTrue);

    await tester.tap(find.text('Maps'));
    await tester.pump();
    expect(tester.state(find.byType(ml.MapLibreMap)), isNot(same(fullState)));
    final newFullMap = tester.widget<ml.MapLibreMap>(
      find.byType(ml.MapLibreMap),
    );
    final newFullController = _MapController();
    newFullMap.onMapCreated!(newFullController);
    expect(newFullController.localRequestsEnabled, isTrue);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomePage)),
    );
    final now = DateTime.now().toUtc();
    final share = PeerLocationShare.fromChat(
      ChatMessage(
        id: 'location-test',
        conversationId: PeerLocationShare.conversationId,
        sender: const Peer(
          id: 'nearby-responder',
          name: 'Phone model',
          type: PeerType.responder,
          isConnected: false,
        ),
        recipient: const Peer(
          id: 'test',
          name: 'This phone',
          type: PeerType.civilian,
          isConnected: false,
        ),
        body: '{"latitude":7.31,"longitude":125.6915}',
        status: MessageStatus.received,
        createdAt: now,
        ttl: const Duration(minutes: 15),
      ),
      ownerName: 'Approved responder',
      now: now,
      expiresAt: now.add(const Duration(minutes: 15)),
    );
    container.read(sharedPeerLocationsProvider.notifier).record(share);
    await tester.pump();
    final pin = find.byKey(
      const ValueKey('shared-peer-location-nearby-responder'),
    );
    expect(pin.hitTestable(), findsOneWidget);
    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(find.text('Approved responder'), findsOneWidget);
    expect(find.textContaining('Location shared at'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pump();
    expect(pin, findsOneWidget);

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
    final saveCompletion = Completer<void>();
    var saveCount = 0;
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
            saveCount++;
            await saveCompletion.future;
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
    expect(find.text('Signal unknown'), findsWidgets);
    expect(find.text('Strong Signal'), findsNothing);
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
    expect(find.text('Broadcast to campus responders'), findsOneWidget);
    expect(find.text('No location yet. You can still send.'), findsOneWidget);

    final details = find.byType(TextField);
    await tester.enterText(details, 'Need help near the school.');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(details).controller!.text,
      'Need help near the school.',
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    expect(find.text('Send SOS').hitTestable(), findsOneWidget);
    tester.view.resetViewInsets();
    await tester.pump();

    final update = find.text('Update');
    gpsEnabled = true;
    await tester.ensureVisible(update);
    await tester.tap(update);
    await tester.pump();
    expect(find.text('Location attached'), findsOneWidget);
    expect(find.text('7.3026° N, 125.6888° E'), findsNothing);

    gpsEnabled = false;
    await tester.tap(update);
    await tester.pump();
    expect(
      find.text(
        'Couldn’t update your location. The last location shown will be attached.',
      ),
      findsOneWidget,
    );
    expect(find.text('Location attached'), findsOneWidget);

    final send = find.text('Send SOS');
    await tester.tap(send);
    await tester.pump();
    expect(find.text('Choose an SOS category.'), findsOneWidget);
    expect(saveCount, 0);
    final category = find.text('Medical Assistance');
    await tester.ensureVisible(category);
    await tester.tap(category);
    await tester.pump();
    await tester.tap(send);
    await tester.pump();
    expect(find.text('Saving SOS…'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Saving SOS…'), findsOneWidget);
    expect(saveCount, 1);
    saveCompletion.complete();
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

  testWidgets(
    'nearby tab aligns stats columns, keeps filter labels unshrunk, and handles 200% text scale',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final originalFactory = ml.MapLibrePlatform.createInstance;
      ml.MapLibrePlatform.createInstance = _MapPlatform.new;
      addTearDown(() => ml.MapLibrePlatform.createInstance = originalFactory);
      SharedPreferences.setMockInitialValues({});
      addTearDown(() => SharedPreferences.setMockInitialValues({}));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            nearbyPeersProvider.overrideWith((ref) async => const []),
            sosMessagesProvider.overrideWith((ref) async => const []),
            conversationsProvider.overrideWith((ref) async => const []),
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
          ],
          child: const MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
              child: HomePage(
                accessProfile: DeviceAccessProfile.unregistered(deviceId: 'test'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Nearby'));
      await tester.pump();

      expect(tester.takeException(), isNull);

      final connectedTop = tester.getTopLeft(find.text('Connected').first).dy;
      final listedTop = tester.getTopLeft(find.text('Listed')).dy;
      final respondersTop = tester
          .getTopLeft(find.text('Campus responders').first)
          .dy;
      expect(listedTop, connectedTop);
      expect(respondersTop, connectedTop);

      for (final label in const [
        'All Peers',
        'Connected',
        'Campus responders',
        'On map',
      ]) {
        final textFinder = find.text(label).last;
        expect(textFinder, findsOneWidget);
        expect(
          find.ancestor(of: textFinder, matching: find.byType(FittedBox)),
          findsNothing,
        );
        final textWidget = tester.widget<Text>(textFinder);
        expect(textWidget.style?.fontSize, 13.5);
      }

      final helper = tester.widget<Text>(
        find.text(
          'Send one location pin to approved nearby phones for 15 minutes.',
        ),
      );
      expect(helper.style?.fontSize, 13);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    },
  );

  testWidgets(
    'verified student opens incoming SOS details without respond or technical fields',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final originalFactory = ml.MapLibrePlatform.createInstance;
      ml.MapLibrePlatform.createInstance = _MapPlatform.new;
      addTearDown(() => ml.MapLibrePlatform.createInstance = originalFactory);
      SharedPreferences.setMockInitialValues({});
      addTearDown(() => SharedPreferences.setMockInitialValues({}));

      final now = DateTime.now().toUtc();
      final incomingBroadcast = SosMessage(
        id: 'sos-incoming-1',
        sender: const Peer(
          id: 'sender-device-1',
          name: 'Ana Cruz',
          type: PeerType.civilian,
          isConnected: false,
        ),
        body: 'Trapped near Science Building.',
        category: Category.medical,
        latitude: 7.3026,
        longitude: 125.6888,
        gpsAccuracyMeters: 5.0,
        hopCount: 2,
        ttl: const Duration(hours: 24),
        messageHash:
            'abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567',
        status: MessageStatus.received,
        receivedAt: now,
        createdAt: now.subtract(const Duration(minutes: 2)),
        trustStatus: DeviceTrustStatus.approved,
        trustOwnerName: 'Ana Cruz',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            nearbyPeersProvider.overrideWith(
              (ref) async => const [
                Peer(
                  id: 'peer-device-99',
                  name: 'Campus Peer',
                  type: PeerType.civilian,
                  isConnected: true,
                ),
              ],
            ),
            sosMessagesProvider.overrideWith((ref) async => [incomingBroadcast]),
            conversationsProvider.overrideWith((ref) async => const []),
            mapTileCacheStoreProvider.overrideWith(
              (ref) async => MemCacheStore(),
            ),
            relayRuntimeProvider.overrideWith(_NoopRelayRuntime.new),
            localPeerProvider.overrideWith(
              (ref) async => const Peer(
                id: 'student-local',
                name: 'Student Local',
                type: PeerType.civilian,
                isConnected: false,
              ),
            ),
          ],
          child: const MaterialApp(
            home: HomePage(
              accessProfile: DeviceAccessProfile(
                level: DeviceAccessLevel.civilian,
                deviceId: 'student-local',
                ownerName: 'Student Local',
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Nearby'));
      await tester.pump();
      expect(find.text('Campus Peer'), findsOneWidget);
      expect(find.text('ID: peer-device-99'), findsNothing);

      await tester.tap(find.text('Messages'));
      await tester.pump();
      final sosCard = find.byKey(const ValueKey('sos-card-sos-incoming-1'));
      expect(sosCard, findsOneWidget);
      await tester.tap(sosCard);
      await tester.pumpAndSettle();

      expect(find.text('SOS details'), findsOneWidget);
      expect(find.text('Location attached'), findsOneWidget);
      expect(find.text('Show on map'), findsOneWidget);
      expect(find.text('Message sender'), findsOneWidget);
      expect(find.text('Mark responded'), findsNothing);
      expect(find.text('Delivery details'), findsNothing);
      expect(find.text('TTL'), findsNothing);
      expect(find.text('Hop count'), findsNothing);
      expect(find.textContaining('7.30260'), findsNothing);

      await tester.tap(find.byTooltip('Close SOS details'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    },
  );
}
