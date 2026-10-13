import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/models/sos_message_payload.dart';
import 'package:shadownetwork/features/messaging/data/repositories/sqlite_sos_message_repository.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/database_migration_test_harness.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  final createdAt = DateTime.utc(2026, 10, 13, 2);
  final message = SosMessage(
    id: 'sos-receipt',
    sender: const Peer(
      id: 'victim',
      name: 'Resident',
      type: PeerType.civilian,
      isConnected: false,
    ),
    body: 'Need rescue',
    category: Category.rescue,
    status: MessageStatus.queued,
    createdAt: createdAt,
  );

  test('propagation handles absent receipt, zero delay and clock mismatch', () {
    expect(message.receivedAt, isNull);
    expect(message.propagationDuration, isNull);
    expect(
      message.copyWith(receivedAt: createdAt).propagationDuration,
      Duration.zero,
    );
    final received = message.copyWith(
      receivedAt: createdAt.add(const Duration(seconds: 102)),
    );
    expect(received.propagationDuration, const Duration(seconds: 102));
    final skewedAt = createdAt.subtract(const Duration(seconds: 30));
    final skewed = message.copyWith(receivedAt: skewedAt);
    expect(skewed.receivedAt, skewedAt);
    expect(skewed.propagationDuration, isNull);
  });

  test('copyWith preserves and explicitly clears receipt metadata', () {
    final received = message.copyWith(
      receivedAt: createdAt.add(const Duration(minutes: 1)),
      receivedFromPeerId: 'relay',
      receivedTransport: 'bluetooth',
      transferId: 'attempt-1',
    );
    final updated = received.copyWith(status: MessageStatus.delivered);
    expect(updated.receivedAt, received.receivedAt);
    expect(updated.receivedFromPeerId, 'relay');
    expect(updated.receivedTransport, 'bluetooth');
    expect(updated.transferId, 'attempt-1');
    final cleared = received.copyWith(
      receivedAt: null,
      receivedFromPeerId: null,
      receivedTransport: null,
      transferId: null,
    );
    expect(cleared.receivedAt, isNull);
    expect(cleared.receivedFromPeerId, isNull);
    expect(cleared.receivedTransport, isNull);
    expect(cleared.transferId, isNull);
  });

  test('local receipt metadata does not change the SOS payload or hash', () {
    final received = message.copyWith(
      receivedAt: createdAt.add(const Duration(minutes: 2)),
      receivedFromPeerId: 'relay',
      receivedTransport: 'wifi_direct',
      transferId: 'attempt-1',
    );
    expect(
      SosMessagePayload.messageHash(received),
      SosMessagePayload.messageHash(message),
    );
    expect(
      SosMessagePayload.canonicalJson(received),
      SosMessagePayload.canonicalJson(message),
    );
  });

  test('receipt survives restart and subsequent message updates', () async {
    final harness = await DatabaseMigrationTestHarness.create();
    addTearDown(harness.dispose);
    final database = await harness.openCurrentDatabase();
    final receipt = DateTime.parse('2026-10-13T10:01:42+08:00');
    final received = message.copyWith(
      status: MessageStatus.received,
      receivedAt: receipt,
      receivedFromPeerId: 'relay-2',
      receivedTransport: 'bluetooth',
      transferId: 'attempt-1',
      hopCount: 3,
    );
    final repository = SqliteSosMessageRepository(database: database);
    await repository.saveMessage(received);
    final row = (await database.query('sos_messages')).single;
    expect(row['received_at'], '2026-10-13T02:01:42.000Z');
    await database.close();

    final reopened = await harness.openCurrentDatabase();
    addTearDown(reopened.close);
    final reloadedRepository = SqliteSosMessageRepository(database: reopened);
    var stored = (await reloadedRepository.getMessages()).single;
    expect(stored.createdAt, createdAt);
    expect(stored.receivedAt, receipt.toUtc());
    expect(stored.receivedAt!.isUtc, isTrue);
    expect(stored.propagationDuration, const Duration(seconds: 102));
    expect(stored.receivedFromPeerId, 'relay-2');
    expect(stored.receivedTransport, 'bluetooth');
    expect(stored.transferId, 'attempt-1');
    expect(stored.hopCount, 3);

    await reloadedRepository.saveMessage(
      message.copyWith(status: MessageStatus.delivered),
    );
    await reloadedRepository.saveMessage(
      received.copyWith(
        receivedAt: receipt.add(const Duration(minutes: 5)),
        receivedFromPeerId: 'another-relay',
        receivedTransport: 'wifi_direct',
        transferId: 'attempt-2',
      ),
    );
    stored = (await reloadedRepository.getMessages()).single;
    expect(stored.receivedAt, receipt.toUtc());
    expect(stored.receivedFromPeerId, 'relay-2');
    expect(stored.receivedTransport, 'bluetooth');
    expect(stored.transferId, 'attempt-1');
  });
}
