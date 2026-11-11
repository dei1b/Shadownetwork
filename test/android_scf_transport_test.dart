import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/services/android_scf_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rejects malformed envelopes and returns valid neighbors in order',
    () async {
      const channel = MethodChannel('test/android_transport');
      final transport = AndroidScfTransport(channel: channel);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final acknowledgements = <Object?>[];
      const valid = <String, Object?>{
        'messageHash': 'hash',
        'payloadJson': '{"payload_type":"sos_message"}',
        'hopCount': 1,
        'receivedAt': '2026-11-11T00:00:00Z',
        'expiresAt': '2026-11-12T00:00:00Z',
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'acknowledgeEnvelope') {
          acknowledgements.add(call.arguments);
          throw PlatformException(code: 'ROUTE_CLOSED');
        }
        expect(call.method, 'receiveEnvelopes');
        return [
          {...valid, 'transferId': 'first'},
          {...valid, 'transferId': 'bad-date', 'receivedAt': 'invalid'},
          {...valid, 'transferId': 'bad-type', 'payloadJson': '[]'},
          {...valid, 'transferId': 'last'},
        ];
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        channel.setMethodCallHandler(null);
      });

      final envelopes = await transport.receiveEnvelopes();
      expect(envelopes.map((envelope) => envelope.transferId), [
        'first',
        'last',
      ]);
      expect(acknowledgements, [
        {'transferId': 'bad-date', 'messageHash': 'hash', 'accepted': false},
        {'transferId': 'bad-type', 'messageHash': 'hash', 'accepted': false},
      ]);
    },
  );
}
