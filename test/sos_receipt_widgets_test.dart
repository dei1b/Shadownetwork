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
        await tester.ensureVisible(find.byTooltip('Copy full message hash'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Copy full message hash'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(SosDetailSheet),
            matching: find.text(
              fails ? 'Unable to copy message hash' : 'Message hash copied',
            ),
          ),
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
              textScaler: TextScaler.linear(1.5),
            ),
            child: SosDetailSheet(message: _message(), onMessageSender: () {}),
          ),
          () => _now,
        ),
      );
      await tester.ensureVisible(find.text('Message sender'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Message sender'), findsOneWidget);
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
    for (final label in [
      'Created time',
      'Received time',
      'Hop count',
      'Last transport',
      'Sender',
      'Last relay peer',
      'Message hash',
      'GPS accuracy',
      'TTL',
      'Trust',
      'Moderation',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('2026-10-14 02:00:00 UTC'), findsOneWidget);
    expect(find.text('2026-10-14 02:01:42 UTC'), findsOneWidget);
    expect(find.text('relay-b'), findsOneWidget);
    expect(find.text('±8.5 m'), findsOneWidget);
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
      expect(find.text('Not recorded'), findsNWidgets(5));
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
