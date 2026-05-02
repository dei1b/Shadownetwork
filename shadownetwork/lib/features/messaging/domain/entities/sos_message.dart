import 'category.dart';
import 'message_status.dart';
import 'peer.dart';

class SosMessage {
  const SosMessage({
    required this.id,
    required this.sender,
    required this.body,
    required this.category,
    required this.status,
    required this.createdAt,
    this.updatedAt,
    this.latitude,
    this.longitude,
  });

  final String id;
  final Peer sender;
  final String body;
  final Category category;
  final MessageStatus status;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final double? latitude;
  final double? longitude;

  SosMessage copyWith({
    String? id,
    Peer? sender,
    String? body,
    Category? category,
    MessageStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    double? latitude,
    double? longitude,
  }) {
    return SosMessage(
      id: id ?? this.id,
      sender: sender ?? this.sender,
      body: body ?? this.body,
      category: category ?? this.category,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
    );
  }
}
