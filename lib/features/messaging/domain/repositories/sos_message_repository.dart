import '../entities/sos_message.dart';

abstract class SosMessageRepository {
  Future<List<SosMessage>> getMessages();
  Future<List<SosMessage>> getRecentMessagesBySender({
    required String senderPeerId,
    required DateTime since,
  });
  Future<void> saveMessage(SosMessage message);
}
