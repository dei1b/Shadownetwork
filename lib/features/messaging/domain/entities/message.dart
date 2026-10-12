class Message {
  const Message({
    required this.id,
    required this.senderName,
    required this.body,
    required this.sentAt,
    required this.isRelayed,
    this.latitude,
    this.longitude,
  });

  final String id;
  final String senderName;
  final String body;
  final DateTime sentAt;
  final bool isRelayed;
  final double? latitude;
  final double? longitude;
}
