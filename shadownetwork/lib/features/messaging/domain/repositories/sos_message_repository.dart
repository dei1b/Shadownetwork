import '../entities/sos_message.dart';

abstract class SosMessageRepository {
  Future<List<SosMessage>> getMessages();
  Future<void> saveMessage(SosMessage message);
}
