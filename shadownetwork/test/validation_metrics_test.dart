import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/messaging/data/services/mock_scf_transport.dart';
import 'package:shadownetwork/features/messaging/data/services/scf_relay_service.dart';
import 'package:shadownetwork/features/messaging/data/services/scf_service.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/validation/data/repositories/sqlite_validation_metrics_repository.dart';
import 'package:shadownetwork/features/validation/domain/entities/validation_event.dart';
import 'package:shadownetwork/features/validation/domain/entities/validation_session.dart';
import 'package:shadownetwork/features/validation/domain/entities/validation_session_data.dart';
import 'package:shadownetwork/features/validation/domain/services/validation_export_service.dart';
import 'package:shadownetwork/features/validation/domain/services/validation_metrics_calculator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/database_migration_test_harness.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('persists active session across database restart', () async {
    final harness = await DatabaseMigrationTestHarness.create();
    addTearDown(harness.dispose);
    final database = await harness.openCurrentDatabase();
    final repository = SqliteValidationMetricsRepository(database: database);
    final startedAt = DateTime.utc(2026, 8, 15, 8);
    final session = await repository.startSession(
      name: 'Three-device field test',
      environment: 'Outdoor field test',
      deviceId: 'responder-1',
      deviceRole: 'responder',
      startedAt: startedAt,
    );
    await database.close();

    final reopened = await harness.openCurrentDatabase();
    addTearDown(reopened.close);
    final reloaded = SqliteValidationMetricsRepository(database: reopened);
    final active = await reloaded.getActiveSession();

    expect(active?.id, session.id);
    expect(active?.startedAt, startedAt);
    expect(active?.deviceId, 'responder-1');
  });

  test('event IDs are duplicate-safe and owned by their session', () async {
    final database = await LocalMessagingDatabase.open(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    addTearDown(database.close);
    final repository = SqliteValidationMetricsRepository(database: database);
    final session = await repository.startSession(
      name: 'Deduplication test',
      environment: 'Laboratory simulation',
      deviceId: 'relay-1',
      deviceRole: 'relay',
      startedAt: DateTime.utc(2026, 8, 15, 8),
    );
    final event = ValidationMessageEvent(
      id: 'stable-event-id',
      sessionId: session.id,
      type: ValidationEventType.envelopeReceived,
      occurredAt: DateTime.utc(2026, 8, 15, 8, 0, 2),
      messageHash: 'hash-1',
      hopCount: 1,
    );

    expect(await repository.recordEvent(event), isTrue);
    expect(await repository.recordEvent(event), isFalse);
    final data = await repository.getSessionData(session.id);

    expect(data.events, hasLength(1));
    expect(data.events.single.sessionId, session.id);
    expect(data.events.single.occurredAt, event.occurredAt);
  });

  test('calculates required metrics only from stored evidence', () {
    final data = _completeSessionData();
    final summary = const ValidationMetricsCalculator().calculate(data);

    expect(summary.telemetryRecordCount, 8);
    expect(summary.deliverySuccessRate, 1);
    expect(summary.discoverySuccessRate, 0.5);
    expect(summary.averageNodeLatencyMs, 200);
    expect(summary.averagePropagationMs, 5000);
    expect(summary.hopDistribution, {2: 1});
    expect(summary.transportUsage, {'bluetooth': 1});
    expect(summary.fallbackRate, 1);
    expect(summary.batteryConsumedPercent, 3);
    expect(summary.batteryConsumedPerHour, 3);
  });

  test('receiver calculates propagation from the payload creation time', () {
    final startedAt = DateTime.utc(2026, 8, 15, 8);
    final data = ValidationSessionData(
      session: ValidationSession(
        id: 'receiver-session',
        name: 'Receiver test',
        environment: 'Outdoor field test',
        deviceId: 'receiver-1',
        deviceRole: 'responder',
        startedAt: startedAt,
        status: ValidationSessionStatus.active,
      ),
      events: [
        ValidationMessageEvent(
          id: 'received',
          sessionId: 'receiver-session',
          type: ValidationEventType.envelopeReceived,
          occurredAt: startedAt.add(const Duration(seconds: 4)),
          messageHash: 'remote-hash',
          metadata: {'message_created_at': startedAt.toIso8601String()},
        ),
        ValidationMessageEvent(
          id: 'delivered',
          sessionId: 'receiver-session',
          type: ValidationEventType.envelopeDelivered,
          occurredAt: startedAt.add(const Duration(seconds: 5)),
          messageHash: 'remote-hash',
          hopCount: 2,
        ),
      ],
      discoveryAttempts: const [],
      batterySamples: const [],
      exportRecords: const [],
    );

    final summary = const ValidationMetricsCalculator().calculate(data);

    expect(summary.deliverySuccessRate, 1);
    expect(summary.averagePropagationMs, 5000);
  });

  test('JSON export-import round trip and CSV preserve real records', () {
    const service = ValidationExportService();
    final source = _completeSessionData();

    final json = service.encodeJson(source);
    final decoded = service.decodeJson(json);
    final csv = service.encodeCsv(source);

    expect(decoded.session.id, source.session.id);
    expect(decoded.events.map((event) => event.id), [
      'queued',
      'offered',
      'sent',
      'delivered',
    ]);
    expect(decoded.discoveryAttempts, hasLength(2));
    expect(decoded.batterySamples, hasLength(2));
    expect(csv, contains('message_event,queued'));
    expect(csv, contains('discovery_attempt,discovery-success'));
    expect(csv, contains('battery_sample,battery-start'));
  });

  test(
    'repository imports an exported session without duplicate rows',
    () async {
      final database = await LocalMessagingDatabase.open(
        databasePath: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      addTearDown(database.close);
      final repository = SqliteValidationMetricsRepository(database: database);
      final data = _completeSessionData();

      await repository.importSessionData(data);
      await repository.importSessionData(data);
      final imported = await repository.getSessionData(data.session.id);

      expect(imported.events, hasLength(4));
      expect(imported.discoveryAttempts, hasLength(2));
      expect(imported.batterySamples, hasLength(2));
    },
  );

  test('SCF relay records offered and successful transport events', () async {
    final database = await LocalMessagingDatabase.open(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    addTearDown(database.close);
    final metrics = SqliteValidationMetricsRepository(database: database);
    final session = await metrics.startSession(
      name: 'Relay instrumentation',
      environment: 'Laboratory simulation',
      deviceId: 'sender-1',
      deviceRole: 'civilian',
      startedAt: DateTime.utc(2026, 8, 15, 8),
    );
    final network = MockScfTransportNetwork();
    final sender = const Peer(
      id: 'sender-1',
      name: 'Sender',
      type: PeerType.civilian,
      isConnected: true,
      transport: 'mock',
    );
    final receiver = const Peer(
      id: 'receiver-1',
      name: 'Receiver',
      type: PeerType.responder,
      isConnected: true,
      transport: 'mock',
    );
    final endpoint = network.registerPeer(sender);
    network.registerPeer(receiver);
    final scf = ScfService(database: database);
    await scf.storeMessage(
      SosMessage(
        id: 'sos-metric-1',
        sender: sender,
        body: 'Need rescue.',
        category: Category.rescue,
        status: MessageStatus.queued,
        createdAt: DateTime.utc(2026, 8, 15, 8),
      ),
      receivedAt: DateTime.utc(2026, 8, 15, 8),
    );
    final relay = ScfRelayService(
      scfService: scf,
      transport: endpoint,
      metricsRecorder: metrics,
    );

    final result = await relay.relayToPeer(
      receiver,
      now: DateTime.utc(2026, 8, 15, 8, 0, 1),
    );
    final data = await metrics.getSessionData(session.id);

    expect(result.sentCount, 1);
    expect(data.events.map((event) => event.type), [
      ValidationEventType.envelopeOffered,
      ValidationEventType.envelopeSent,
    ]);
    expect(data.events.last.transport, 'mock');
    expect(data.events.last.latencyMs, isNotNull);
  });
}

ValidationSessionData _completeSessionData() {
  final startedAt = DateTime.utc(2026, 8, 15, 8);
  const sessionId = 'session-metrics-1';
  return ValidationSessionData(
    session: ValidationSession(
      id: sessionId,
      name: 'Three-device field test',
      environment: 'Outdoor field test',
      deviceId: 'responder-1',
      deviceRole: 'responder',
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(hours: 1)),
      status: ValidationSessionStatus.completed,
    ),
    events: [
      ValidationMessageEvent(
        id: 'queued',
        sessionId: sessionId,
        type: ValidationEventType.sosQueued,
        occurredAt: startedAt,
        messageHash: 'hash-1',
        payloadType: 'sos_message',
        hopCount: 0,
      ),
      ValidationMessageEvent(
        id: 'offered',
        sessionId: sessionId,
        type: ValidationEventType.envelopeOffered,
        occurredAt: startedAt.add(const Duration(seconds: 1)),
        messageHash: 'hash-1',
        peerId: 'relay-1',
        hopCount: 1,
      ),
      ValidationMessageEvent(
        id: 'sent',
        sessionId: sessionId,
        type: ValidationEventType.envelopeSent,
        occurredAt: startedAt.add(const Duration(seconds: 2)),
        messageHash: 'hash-1',
        peerId: 'relay-1',
        transport: 'bluetooth',
        hopCount: 1,
        latencyMs: 200,
        fallbackUsed: true,
      ),
      ValidationMessageEvent(
        id: 'delivered',
        sessionId: sessionId,
        type: ValidationEventType.envelopeDelivered,
        occurredAt: startedAt.add(const Duration(seconds: 5)),
        messageHash: 'hash-1',
        peerId: 'responder-1',
        hopCount: 2,
      ),
    ],
    discoveryAttempts: [
      ValidationDiscoveryAttempt(
        id: 'discovery-success',
        sessionId: sessionId,
        transport: 'hybrid',
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        discoveredCount: 2,
        success: true,
      ),
      ValidationDiscoveryAttempt(
        id: 'discovery-empty',
        sessionId: sessionId,
        transport: 'hybrid',
        startedAt: startedAt.add(const Duration(minutes: 1)),
        endedAt: startedAt.add(const Duration(minutes: 1, seconds: 1)),
        discoveredCount: 0,
        success: false,
      ),
    ],
    batterySamples: [
      ValidationBatterySample(
        id: 'battery-start',
        sessionId: sessionId,
        batteryPercent: 90,
        isCharging: false,
        sampledAt: startedAt,
        runtimeMode: 'foreground',
      ),
      ValidationBatterySample(
        id: 'battery-end',
        sessionId: sessionId,
        batteryPercent: 87,
        isCharging: false,
        sampledAt: startedAt.add(const Duration(hours: 1)),
        runtimeMode: 'active_relay',
      ),
    ],
    exportRecords: const [],
  );
}
