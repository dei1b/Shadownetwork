import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/models/sos_message_payload.dart';
import 'package:shadownetwork/features/messaging/data/services/scf_service.dart';
import 'package:shadownetwork/features/messaging/data/repositories/sqlite_sos_message_repository.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/messaging/presentation/utils/message_feed_filter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/database_migration_test_harness.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'civilian archive survives upgrade and restart without changing the queue',
    () async {
      final harness = await DatabaseMigrationTestHarness.create();
      addTearDown(harness.dispose);
      var db = await harness.openCurrentDatabase();
      addTearDown(() => db.close());
      var repository = SqliteSosMessageRepository(database: db);
      final own = SosMessage(
        id: 'own',
        sender: const Peer(
          id: 'civilian',
          name: 'Resident',
          type: PeerType.civilian,
          isConnected: false,
        ),
        body: 'Test alert',
        category: Category.medical,
        status: MessageStatus.queued,
        createdAt: DateTime.now().toUtc(),
        latitude: 7.3,
        longitude: 125.7,
      );
      final payload = SosMessagePayload.canonicalJson(own);
      await repository.saveMessage(own, outgoingPayloadJson: payload);
      await db.execute('ALTER TABLE sos_messages DROP COLUMN archived_at');
      await db.setVersion(16);
      await db.close();
      db = await harness.openCurrentDatabase();
      repository = SqliteSosMessageRepository(database: db);
      expect((await repository.getMessages()).single.archivedAt, isNull);
      expect(
        await repository.setArchived(
          messageId: own.id,
          localPeerId: 'another-phone',
          archived: true,
        ),
        isFalse,
      );
      Future<bool> archive(bool value) => repository.setArchived(
        messageId: own.id,
        localPeerId: 'CIVILIAN',
        archived: value,
      );
      final scfBeforeRestart = ScfService(database: db);
      final prepared = (await scfBeforeRestart.prepareOutboundForPeer(
        'relay',
      )).single;
      expect(await archive(true), isTrue);
      expect(
        await scfBeforeRestart.isOutboundOfferActive(
          prepared.messageHash,
          'relay',
        ),
        isFalse,
      );
      await scfBeforeRestart.releaseOutboundOffer(
        prepared.messageHash,
        'relay',
      );
      expect(await scfBeforeRestart.prepareOutboundForPeer('relay'), isEmpty);
      expect(await scfBeforeRestart.hasRecentQueuedEnvelopes(), isFalse);
      await repository.saveMessage(own);
      await db.close();
      db = await harness.openCurrentDatabase();
      repository = SqliteSosMessageRepository(database: db);
      final archived = (await repository.getMessages()).single;
      expect(archived.archivedAt, isNotNull);
      expect(archived.respondedAt, isNull);
      expect(archived.status, MessageStatus.queued);
      expect(
        (await ScfService(
          database: db,
        ).getStoredEnvelopes()).single.payloadJson,
        payload,
      );
      expect(
        shouldShowSosMessageOnMap(
          message: archived,
          visibleCategories: {Category.medical},
        ),
        isFalse,
      );
      expect(await archive(false), isTrue);
      expect((await repository.getMessages()).single.archivedAt, isNull);
      final resumed = (await ScfService(
        database: db,
      ).prepareOutboundForPeer('relay')).single;
      expect(resumed.messageHash, prepared.messageHash);
      expect(resumed.expiresAt, prepared.expiresAt);
    },
  );

  test(
    'SOS archive survives an upgrade, repeat receipt, and restart',
    () async {
      final harness = await DatabaseMigrationTestHarness.create();
      addTearDown(harness.dispose);
      var db = await harness.openCurrentDatabase();
      addTearDown(() => db.close());
      var repository = SqliteSosMessageRepository(database: db);
      final now = DateTime.now().toUtc();
      final alert = SosMessage(
        id: 'alert',
        sender: const Peer(
          id: 'resident',
          name: 'Resident',
          type: PeerType.civilian,
          isConnected: false,
        ),
        body: 'Need help',
        category: Category.medical,
        status: MessageStatus.received,
        createdAt: now,
        receivedAt: now,
        latitude: 7.3,
        longitude: 125.7,
      );
      await repository.saveMessage(alert);
      await db.execute('ALTER TABLE sos_messages DROP COLUMN responded_at');
      await db.setVersion(15);
      await db.close();
      db = await harness.openCurrentDatabase();
      repository = SqliteSosMessageRepository(database: db);
      final upgraded = (await repository.getMessages()).single;
      expect(upgraded.body, alert.body);
      expect(upgraded.respondedAt, isNull);
      bool showsOnMap(SosMessage item) => shouldShowSosMessageOnMap(
        message: item,
        visibleCategories: {Category.medical},
      );
      expect(showsOnMap(upgraded), isTrue);
      expect(
        await repository.setResponded(
          messageId: alert.id,
          localPeerId: 'RESIDENT',
          responded: true,
        ),
        isFalse,
      );
      Future<bool> respond(bool value) => repository.setResponded(
        messageId: alert.id,
        localPeerId: 'rescuer',
        responded: value,
      );
      expect(await respond(true), isTrue);
      expect(await respond(true), isFalse);
      final respondedAt = (await repository.getMessages()).single.respondedAt;
      expect(respondedAt, isNotNull);
      await repository.saveMessage(
        alert.copyWith(receivedAt: now.add(const Duration(seconds: 3))),
      );
      await db.close();
      db = await harness.openCurrentDatabase();
      repository = SqliteSosMessageRepository(database: db);
      final archived = (await repository.getMessages()).single;
      expect(archived.respondedAt, respondedAt);
      expect(archived.receivedAt, now);
      expect(showsOnMap(archived), isFalse);
      bool showsIn(String filter) => shouldShowSosMessageForFilter(
        message: archived,
        messageType: 'SOS',
        activeFilter: filter,
      );
      expect(showsIn('ALL'), isFalse);
      expect(showsIn('SOS'), isFalse);
      expect(showsIn('ARCHIVE'), isTrue);
      expect(await respond(false), isTrue);
      expect(showsOnMap((await repository.getMessages()).single), isTrue);
    },
  );
}
