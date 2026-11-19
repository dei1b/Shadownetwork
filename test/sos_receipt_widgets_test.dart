import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_moderation_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/sos_clock_provider.dart';
import 'package:shadownetwork/features/messaging/presentation/widgets/sos_detail_sheet.dart';
import 'package:shadownetwork/features/messaging/presentation/widgets/sos_receipt_summary.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_trust_status.dart';

final _createdAt = DateTime.utc(2026, 10, 14, 2);
final _receivedAt = _createdAt.add(const Duration(minutes: 1, seconds: 42));
final _now = _receivedAt.add(const Duration(seconds: 18));
const _hash =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  testWidgets('detail warns about reversed clocks and keeps raw timestamps', (
    tester,
  ) async {
    final receipt = _createdAt.subtract(const Duration(seconds: 1));
    await tester.pumpWidget(
      _app(
        SosDetailSheet(
          message: _message().copyWith(receivedAt: receipt),
          onMessageSender: () {},
        ),
        () => _now,
      ),
    );
    expect(find.text('2026-10-14 01:59:59 UTC'), findsOneWidget);
    expect(find.text('Clock mismatch detected'), findsNothing);
    await _toggleDeliveryDetails(tester);
    expect(find.text('Clock mismatch detected'), findsOneWidget);
    expect(
      find.textContaining('The receipt precedes creation.'),
      findsOneWidget,
    );
    expect(find.text('2026-10-14 01:59:59 UTC'), findsOneWidget);
    expect(find.textContaining('Travel time -'), findsNothing);
  });

  for (final fails in [false, true]) {
    testWidgets(
      'hash copy ${fails ? 'failure' : 'confirmation'} is visible inside modal',
      (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (fails && call.method == 'Clipboard.setData') {
              throw PlatformException(code: 'clipboard_unavailable');
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(
          _app(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showSosDetailSheet(
                  context,
                  message: _message(),
                  onMessageSender: () {},
                ),
                child: const Text('Open SOS'),
              ),
            ),
            () => _now,
          ),
        );
        await tester.tap(find.text('Open SOS'));
        await tester.pumpAndSettle();
        await _toggleDeliveryDetails(tester);
        await tester.ensureVisible(find.byTooltip('Copy full message hash'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Copy full message hash'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(SosDetailSheet),
            matching: find.text(
              fails
                  ? 'Unable to copy message hash. Try again.'
                  : 'Message hash copied',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.text(fails ? 'Action failed' : 'Completed'),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    'compact receipt ticks without rebuilding parent or changing travel time',
    (tester) async {
      var now = _now;
      var parentBuilds = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sosClockProvider.overrideWith(
              () => SosClockController(now: () => now),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  parentBuilds++;
                  return SosReceiptSummary(message: _message());
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('Received 18s ago'), findsOneWidget);
      expect(find.text('Travel time 1m 42s • 3 hops'), findsOneWidget);
      expect(find.text('Last hop: Bluetooth (BLE)'), findsOneWidget);
      final initialBuilds = parentBuilds;
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Received 19s ago'), findsOneWidget);
      expect(find.text('Travel time 1m 42s • 3 hops'), findsOneWidget);
      expect(parentBuilds, initialBuilds);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      // Auto-disposal cancels the timer; no mounted provider is touched later.
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('clock pauses with app and refreshes immediately on resume', (
    tester,
  ) async {
    var now = _now;
    await tester.pumpWidget(
      _app(SosReceiptSummary(message: _message()), () => now),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Received 18s ago'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Received 1m 18s ago'), findsOneWidget);
  });

  testWidgets(
    'local or legacy SOS shows unavailable propagation, not receipt age',
    (tester) async {
      await tester.pumpWidget(
        _app(
          SosReceiptSummary(
            message: _message().copyWith(
              receivedAt: null,
              receivedTransport: null,
              hopCount: 0,
            ),
          ),
          () => _now,
        ),
      );
      expect(find.text('Created 2m 00s ago'), findsOneWidget);
      expect(
        find.text('Propagation time unavailable • Direct'),
        findsOneWidget,
      );
      expect(find.textContaining('Received'), findsNothing);
      expect(find.textContaining('Last hop:'), findsNothing);
    },
  );

  testWidgets('clock skew displays warning instead of a negative travel time', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        SosReceiptSummary(
          message: _message().copyWith(
            receivedAt: _createdAt.subtract(const Duration(seconds: 1)),
            hopCount: 1,
          ),
        ),
        () => _now,
      ),
    );
    expect(find.text('Clock mismatch detected • 1 hop'), findsOneWidget);
    expect(find.textContaining('Travel time -'), findsNothing);
  });

  for (final width in [320.0, 412.0]) {
    testWidgets('summary and details fit width $width with enlarged text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _app(
          MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: TextScaler.linear(1.5),
            ),
            child: SizedBox(
              width: width - 100,
              child: SosReceiptSummary(message: _message()),
            ),
          ),
          () => _now,
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        _app(
          MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: TextScaler.linear(2),
            ),
            child: SosDetailSheet(
              message: _message().copyWith(latitude: 7, longitude: 125),
              onShowOnMap: () {},
              onMessageSender: () {},
              onUpdateResponse: () {},
            ),
          ),
          () => _now,
        ),
      );
      await tester.ensureVisible(find.text('Message sender'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Message sender'), findsOneWidget);
      expect(
        tester.getSize(find.widgetWithText(FilledButton, 'Show on map')).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getBottomLeft(find.text('Message sender')).dy,
        lessThan(tester.getTopLeft(find.text('Delivery details')).dy),
      );
    });
  }

  testWidgets('detail sheet shows persisted evidence and copies full hash', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      _app(
        SosDetailSheet(
          message: _message().copyWith(
            latitude: 7.30263,
            longitude: 125.68881,
            trustOwnerName: 'Registered Resident',
            trustStatus: DeviceTrustStatus.revoked,
            moderationStatus: MessageModerationStatus.spam,
            moderationReason: 'Repeated SOS',
            isEncrypted: true,
          ),
          onMessageSender: () {},
        ),
        () => _now,
      ),
    );
    for (final label in ['Sender', 'Emergency', 'Location', 'Received time']) {
      expect(find.text(label), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(label)).dy,
        lessThan(tester.getTopLeft(find.text('Message sender')).dy),
      );
    }
    expect(find.text('Registered Resident'), findsOneWidget);
    expect(find.text('Medical Assistance'), findsOneWidget);
    expect(find.text('7.30263, 125.68881'), findsOneWidget);
    expect(find.text('GPS accuracy ±8.5 m'), findsOneWidget);
    expect(find.text('2026-10-14 02:01:42 UTC'), findsOneWidget);
    expect(find.text('Hop count'), findsNothing);
    expect(find.text('Trust'), findsNothing);
    await _toggleDeliveryDetails(tester);
    for (final label in [
      'Created time',
      'Hop count',
      'Last transport',
      'Sender device ID',
      'Last relay peer',
      'Message hash',
      'TTL',
      'Trust',
      'Moderation',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('2026-10-14 02:00:00 UTC'), findsOneWidget);
    expect(find.text('relay-b'), findsOneWidget);
    expect(find.text('Revoked • Quarantine'), findsOneWidget);
    expect(find.text('Spam'), findsOneWidget);
    expect(find.text('Repeated SOS'), findsOneWidget);
    expect(find.text('Targeted • Encrypted'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Copy full message hash'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy full message hash'));
    await tester.pumpAndSettle();
    expect(
      calls.where((c) => c.method == 'Clipboard.setData').single.arguments,
      {'text': _hash},
    );
    expect(find.text('Message hash copied'), findsOneWidget);
    await _toggleDeliveryDetails(tester);
    expect(find.text('Hop count'), findsNothing);
    expect(find.text('Registered Resident'), findsOneWidget);
  });

  testWidgets(
    'detail TTL refreshes to expired without changing stored timestamps',
    (tester) async {
      var now = _now;
      await tester.pumpWidget(
        _app(
          SosDetailSheet(
            message: _message().copyWith(ttl: const Duration(seconds: 121)),
            onMessageSender: () {},
          ),
          () => now,
        ),
      );
      await _toggleDeliveryDetails(tester);
      expect(find.text('1s remaining'), findsOneWidget);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Expired'), findsOneWidget);
      expect(find.text('2026-10-14 02:01:42 UTC'), findsOneWidget);
    },
  );

  testWidgets(
    'missing detail metadata has no invented hash, transport, or receipt',
    (tester) async {
      final legacy = SosMessage(
        id: 'legacy',
        sender: _message().sender,
        body: 'Need help',
        category: Category.medical,
        status: MessageStatus.received,
        createdAt: _createdAt,
      );
      await tester.pumpWidget(
        _app(
          SosDetailSheet(message: legacy, onMessageSender: () {}),
          () => _now,
        ),
      );
      expect(find.text('No GPS location attached'), findsOneWidget);
      expect(find.text('Not recorded'), findsOneWidget);
      await _toggleDeliveryDetails(tester);
      expect(find.text('Not recorded'), findsNWidgets(4));
      expect(find.byTooltip('Copy full message hash'), findsNothing);
    },
  );

  testWidgets(
    'modal closes before invoking the existing message-sender action',
    (tester) async {
      var messaged = false;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showSosDetailSheet(
                context,
                message: _message(),
                onMessageSender: () {
                  messaged = true;
                },
              ),
              child: const Text('Open SOS'),
            ),
          ),
          () => _now,
        ),
      );
      await tester.tap(find.text('Open SOS'));
      await tester.pumpAndSettle();
      expect(find.text('SOS details'), findsOneWidget);
      await tester.ensureVisible(find.text('Message sender'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Message sender'));
      await tester.pumpAndSettle();
      expect(messaged, isTrue);
      expect(find.byType(SosDetailSheet), findsNothing);
      await tester.tap(find.text('Open SOS'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close SOS details'));
      await tester.pumpAndSettle();
      expect(find.byType(SosDetailSheet), findsNothing);
    },
  );

  testWidgets('Show on map pops the sheet before calling Home', (tester) async {
    var mapCalls = 0;
    bool? result = true;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showSosDetailSheet(
                context,
                message: _message().copyWith(latitude: 7, longitude: 125),
                canUpdateResponse: true,
                onMessageSender: () {},
                onShowOnMap: () {
                  expect(Navigator.of(context).canPop(), isFalse);
                  mapCalls++;
                },
              );
            },
            child: const Text('Open SOS'),
          ),
        ),
        () => _now,
      ),
    );
    await tester.tap(find.text('Open SOS'));
    await tester.pumpAndSettle();
    final showOnMap = find.widgetWithText(FilledButton, 'Show on map');
    final messageSender = find.widgetWithText(OutlinedButton, 'Message sender');
    final markResponded = find.widgetWithText(OutlinedButton, 'Mark responded');
    for (final action in [showOnMap, messageSender, markResponded]) {
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    }
    expect(
      tester.getTopLeft(showOnMap).dy,
      lessThan(tester.getTopLeft(messageSender).dy),
    );
    await tester.ensureVisible(showOnMap);
    await tester.tap(showOnMap);
    await tester.pumpAndSettle();
    expect(mapCalls, 1);
    expect(result, isNull);
    expect(find.byType(SosDetailSheet), findsNothing);
    expect(find.text('Open SOS'), findsOneWidget);
  });

  testWidgets('Show on map requires both valid coordinates and a callback', (
    tester,
  ) async {
    for (final (message, callback) in [
      (_message().copyWith(latitude: 7), () {}),
      (_message().copyWith(latitude: 91, longitude: 125), () {}),
      (_message().copyWith(latitude: 7, longitude: double.nan), () {}),
      (_message().copyWith(latitude: 7, longitude: 125), null),
    ]) {
      await tester.pumpWidget(
        _app(
          SosDetailSheet(message: message, onShowOnMap: callback),
          () => _now,
        ),
      );
      expect(find.text('Show on map'), findsNothing);
    }
  });

  testWidgets('response and archive actions return an update result', (
    tester,
  ) async {
    for (final (own, archived, label) in [
      (false, false, 'Mark responded'),
      (false, true, 'Restore alert'),
      (true, false, 'Archive SOS'),
      (true, true, 'Restore SOS'),
    ]) {
      bool? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showSosDetailSheet(
                  context,
                  message: _message().copyWith(
                    respondedAt: !own && archived ? _now : null,
                    archivedAt: own && archived ? _now : null,
                  ),
                  ownSenderLabel: own ? 'You' : null,
                  canUpdateArchive: own,
                  canUpdateResponse: !own,
                );
              },
              child: const Text('Open SOS'),
            ),
          ),
          () => _now,
        ),
      );
      await tester.tap(find.text('Open SOS'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(result, isTrue, reason: label);
      expect(find.byType(SosDetailSheet), findsNothing);
    }
  });
}

Future<void> _toggleDeliveryDetails(WidgetTester tester) async {
  final disclosure = find.text('Delivery details');
  await tester.ensureVisible(disclosure);
  await tester.tap(disclosure);
  await tester.pumpAndSettle();
}

Widget _app(Widget child, DateTime Function() now) => ProviderScope(
  overrides: [
    sosClockProvider.overrideWith(() => SosClockController(now: now)),
  ],
  child: MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(body: child),
  ),
);

SosMessage _message() => SosMessage(
  id: 'sos-ui',
  sender: const Peer(
    id: 'resident-a',
    name: 'Resident A',
    type: PeerType.civilian,
    isConnected: false,
  ),
  body: 'Need medical assistance near the barangay hall.',
  category: Category.medical,
  status: MessageStatus.received,
  createdAt: _createdAt,
  receivedAt: _receivedAt,
  receivedFromPeerId: 'relay-b',
  receivedTransport: 'bluetooth',
  transferId: 'attempt-1',
  messageHash: _hash,
  hopCount: 3,
  gpsAccuracyMeters: 8.5,
);
