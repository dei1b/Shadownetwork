import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class IncomingMessageNotifications {
  const IncomingMessageNotifications({
    MethodChannel channel = const MethodChannel(
      'shadow_network/incoming_notifications',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<void> show({required String messageHash, required bool isSos}) async {
    try {
      await _channel.invokeMethod<void>('show', {
        'messageHash': messageHash,
        'isSos': isSos,
      });
    } on PlatformException catch (error) {
      debugPrint('Incoming message notification failed: ${error.code}');
    } on MissingPluginException {
      debugPrint('Incoming message notifications are unavailable.');
    }
  }
}
