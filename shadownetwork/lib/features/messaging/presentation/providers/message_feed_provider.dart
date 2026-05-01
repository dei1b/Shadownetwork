import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/message.dart';

final messageFeedProvider = Provider<List<Message>>((ref) {
  final now = DateTime.now();
  return [
    Message(
      id: 'msg-001',
      senderName: 'Unit Alpha',
      body: 'Medical team en route. Keep path clear near checkpoint 4.',
      sentAt: now.subtract(const Duration(minutes: 4)),
      isRelayed: false,
      latitude: 37.7739,
      longitude: -122.4312,
    ),
    Message(
      id: 'msg-002',
      senderName: 'Relay Node B',
      body: 'Road to shelter east gate is blocked by debris.',
      sentAt: now.subtract(const Duration(minutes: 9)),
      isRelayed: true,
      latitude: 37.7745,
      longitude: -122.4305,
    ),
  ];
});
