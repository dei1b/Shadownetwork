import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/services/android_scf_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/android_receipt');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

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
