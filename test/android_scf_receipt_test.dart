import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/services/android_scf_transport.dart';
import 'package:shadownetwork/features/messaging/domain/entities/envelope_transfer_result.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/scf_envelope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/android_receipt');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  const peer = Peer(
    id: 'receiver',
    name: 'Rescuer',
    type: PeerType.responder,
    isConnected: true,
    transport: 'wifi_direct',
  );
  final envelope = ScfEnvelope(
    messageHash: 'hash',
    payloadJson: '{}',
    hopCount: 1,
    receivedAt: DateTime.utc(2026, 10, 13),
    expiresAt: DateTime.utc(2026, 10, 14),
    transferId: 'attempt',
  );

  test(
    'adaptive power profile is sent to the native relay without changing transport frames',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'setPowerProfile');
        expect(call.arguments, {'profile': 'saving'});
        return null;
      });
      await AndroidScfTransport(channel: channel).setPowerProfile('saving');
    },
  );

  test(
    'Android send passes transfer ID and returns native monotonic ACK latency',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'sendEnvelope');
        expect((call.arguments as Map)['envelope']['transferId'], 'attempt');
        return {
          'transferId': 'attempt',
          'acknowledged': true,
          'latencyMs': 123,
          'sentAt': 1000,
          'acknowledgedAt': 1123,
          'transport': 'bluetooth',
          'fallbackUsed': true,
        };
      });
      final result = await AndroidScfTransport(
        channel: channel,
      ).sendEnvelope(peer: peer, envelope: envelope);
      expect(result.latencyMs, 123);
      expect(result.acknowledged, isTrue);
      expect(result.transferId, 'attempt');
      expect(
        result.sentAt,
        DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      );
      expect(result.acknowledgedAt!.isUtc, isTrue);
      expect(result.fallbackUsed, isTrue);
    },
  );

  test(
    'Android ACK timeout is typed and preserves completed-write evidence',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'ACK_TIMEOUT',
          message: 'No stored ACK',
          details: {
            'sentAt': 1000,
            'latencyMs': 10001,
            'transport': 'wifi_direct',
          },
        );
      });
      await expectLater(
        AndroidScfTransport(
          channel: channel,
        ).sendEnvelope(peer: peer, envelope: envelope),
        throwsA(
          isA<EnvelopeAcknowledgementTimeout>()
              .having((e) => e.transferId, 'transferId', 'attempt')
              .having((e) => e.sentAt, 'sentAt', isNotNull)
              .having((e) => e.code, 'code', 'ack_timeout'),
        ),
      );
    },
  );

  test(
    'Android does not accept a write-only or mismatched native result',
    () async {
      for (final response in [
        {'transport': 'bluetooth'},
        {'transferId': 'wrong-attempt', 'acknowledged': true, 'latencyMs': 100},
      ]) {
        messenger.setMockMethodCallHandler(channel, (call) async => response);
        await expectLater(
          AndroidScfTransport(
            channel: channel,
          ).sendEnvelope(peer: peer, envelope: envelope),
          throwsA(
            isA<EnvelopeTransferException>().having(
              (e) => e.code,
              'code',
              'invalid_ack',
            ),
          ),
        );
      }
    },
  );

  test(
    'Flutter sends storage decision to native bridge with correlation fields',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'acknowledgeEnvelope');
        expect(call.arguments, {
          'transferId': 'attempt',
          'messageHash': 'hash',
          'accepted': false,
        });
        return null;
      });
      await AndroidScfTransport(
        channel: channel,
      ).acknowledgeEnvelope(envelope: envelope, accepted: false);
    },
  );

  for (final hasMetadata in [false, true]) {
    test(
      'Android receive handles ${hasMetadata ? "last-hop metadata" : "legacy frames"}',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'receiveEnvelopes');
          return [
            {
              'messageHash': 'hash',
              'payloadJson': '{"payload_type":"sos_message"}',
              'hopCount': 2,
              'receivedAt': '2026-10-13T02:00:00.000Z',
              'expiresAt': '2026-10-14T02:00:00.000Z',
              if (hasMetadata) ...{
                'receivedFromPeerId': 'relay',
                'receivedTransport': 'wifi_direct',
                'transferId': 'attempt-1',
              },
            },
          ];
        });
        final envelope = (await AndroidScfTransport(
          channel: channel,
        ).receiveEnvelopes()).single;
        expect(envelope.receivedFromPeerId, hasMetadata ? 'relay' : null);
        expect(envelope.receivedTransport, hasMetadata ? 'wifi_direct' : null);
        expect(envelope.transferId, hasMetadata ? 'attempt-1' : null);
      },
    );
  }
}
