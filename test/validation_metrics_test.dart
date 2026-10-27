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
      testRunId: 'FIXTURE-RUN',
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

  test('transfer ID and ACK event survive SQLite reopen and export', () async {
    final harness = await DatabaseMigrationTestHarness.create();
    addTearDown(harness.dispose);
    final db = await harness.openCurrentDatabase();
    final metrics = SqliteValidationMetricsRepository(database: db);
    final session = await metrics.startSession(
      testRunId: 'FIXTURE-RUN',
      name: 'ACK persistence',
      environment: 'Mock',
      deviceId: 'sender',
      deviceRole: 'civilian',
    );
    await metrics.captureEvent(
      type: ValidationEventType.envelopeAcknowledged,
      transferId: 'persisted-transfer',
      messageHash: 'hash',
      peerId: 'receiver',
      transport: 'bluetooth',
      latencyMs: 321,
    );
    await db.close();
    final reopened = await harness.openCurrentDatabase();
    addTearDown(reopened.close);
    final data = await SqliteValidationMetricsRepository(
      database: reopened,
    ).getSessionData(session.id);
    const export = ValidationExportService();
    final decoded = export.decodeJson(export.encodeJson(data));
    expect(decoded.events.single.transferId, 'persisted-transfer');
    expect(
      decoded.events.single.type,
      ValidationEventType.envelopeAcknowledged,
    );
    expect(decoded.events.single.latencyMs, 321);
    expect(export.encodeCsv(data), contains('transfer_id'));
    expect(export.encodeCsv(data), contains('persisted-transfer'));
    final legacy = data.events.single.toJson()..remove('transfer_id');
    expect(ValidationMessageEvent.fromJson(legacy).transferId, isNull);
  });

  test('success and latency exclude legacy writes and deduplicate ACK IDs', () {
    final source = _completeSessionData();
    ValidationSessionData evidence(List<ValidationMessageEvent> events) =>
        ValidationSessionData(
          session: source.session,
          events: events,
          discoveryAttempts: const [],
          batterySamples: const [],
          exportRecords: const [],
        );
    const calculator = ValidationMetricsCalculator();
    final offer = source.events[1];
    final write = source.events[2];
    final ack = source.events[3];
    final legacy = calculator.calculate(evidence([write]));
    expect(legacy.deliverySuccessRate, isNull);
    expect(legacy.averageNodeLatencyMs, isNull);
    final writeOnly = calculator.calculate(evidence([offer, write]));
    expect(writeOnly.deliverySuccessRate, 0);
    expect(writeOnly.averageNodeLatencyMs, isNull);
    final duplicate = ValidationMessageEvent.fromJson(
      ack.toJson()..['id'] = 'duplicate-ack',
    );
    final summary = calculator.calculate(
      evidence([offer, offer, ack, duplicate]),
    );
    expect(summary.deliverySuccessRate, 1);
    expect(summary.averageNodeLatencyMs, 200);
    for (final field in ['peer_id', 'message_hash']) {
      final mismatch = ValidationMessageEvent.fromJson(
        ack.toJson()..[field] = 'wrong',
      );
      expect(
        calculator.calculate(evidence([offer, mismatch])).deliverySuccessRate,
        0,
      );
    }
  });

  test('event IDs are duplicate-safe and owned by their session', () async {
    final database = await LocalMessagingDatabase.open(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    addTearDown(database.close);
    final repository = SqliteValidationMetricsRepository(database: database);
    final session = await repository.startSession(
      testRunId: 'FIXTURE-RUN',
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

    expect(summary.telemetryRecordCount, 9);
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

    expect(summary.deliverySuccessRate, isNull);
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
      'acknowledged',
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

      expect(imported.events, hasLength(5));
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
      testRunId: 'FIXTURE-RUN',
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
    final receivingEndpoint = network.registerPeer(receiver);
    final receiverHarness = await DatabaseMigrationTestHarness.create();
    addTearDown(receiverHarness.dispose);
    final receiverDatabase = await receiverHarness.openCurrentDatabase();
    addTearDown(receiverDatabase.close);
    final receivingRelay = ScfRelayService(
      scfService: ScfService(database: receiverDatabase),
      transport: receivingEndpoint,
    );
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

    final sending = relay.relayToPeer(
      receiver,
      now: DateTime.utc(2026, 8, 15, 8, 0, 1),
    );
    await receivingEndpoint.relayEvents.first;
    await receivingRelay.ingestIncoming(
      now: DateTime.utc(2026, 8, 15, 8, 0, 2),
    );
    final result = await sending;
    final data = await metrics.getSessionData(session.id);

    expect(result.sentCount, 1);
    expect(data.events.map((event) => event.type), [
      ValidationEventType.envelopeOffered,
      ValidationEventType.envelopeSent,
      ValidationEventType.envelopeAcknowledged,
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
        transferId: 'attempt-1',
        sessionId: sessionId,
        type: ValidationEventType.envelopeOffered,
        occurredAt: startedAt.add(const Duration(seconds: 1)),
        messageHash: 'hash-1',
        peerId: 'relay-1',
        hopCount: 1,
      ),
      ValidationMessageEvent(
        id: 'sent',
        transferId: 'attempt-1',
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
        id: 'acknowledged',
        transferId: 'attempt-1',
        sessionId: sessionId,
        type: ValidationEventType.envelopeAcknowledged,
        occurredAt: startedAt.add(const Duration(milliseconds: 2200)),
        messageHash: 'hash-1',
        peerId: 'relay-1',
        transport: 'bluetooth',
        latencyMs: 200,
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
