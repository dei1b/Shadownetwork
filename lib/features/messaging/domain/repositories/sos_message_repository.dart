import '../entities/sos_message.dart';

abstract class SosMessageRepository {
  Future<List<SosMessage>> getMessages();
  Future<List<SosMessage>> getRecentMessagesBySender({
    required String senderPeerId,
    required DateTime since,
  });

  /// Saves the message and returns whether it is new to this phone.
  Future<bool> saveMessage(SosMessage message);
  Future<bool> setResponded({
    required String messageId,
    required String localPeerId,
    required bool responded,
  });
}
