import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/message_status.dart';
import '../../domain/entities/sos_message.dart';
import '../providers/sos_clock_provider.dart';

class SosSendStatus extends ConsumerWidget {
  const SosSendStatus({
    super.key,
    required this.message,
    this.showDeliveryQualifier = true,
  });

  final SosMessage message;
  final bool showDeliveryQualifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final relayDeadline = message.createdAt.add(message.ttl);
    final expired = ref.watch(
      sosClockProvider.select((now) => !now.isBefore(relayDeadline)),
    );
    final qualifier = showDeliveryQualifier ? ' · Delivery unconfirmed' : '';
    final label = switch (message.status) {
      MessageStatus.delivered => 'Delivery confirmed',
      MessageStatus.failed => 'Could not send',
      MessageStatus.draft => 'Draft',
      _ when expired => 'Relay time ended$qualifier',
      _ when message.archivedAt != null => 'Sending paused on this phone',
      MessageStatus.relayed => 'Passed to a nearby phone$qualifier',
      MessageStatus.sent => 'Sent$qualifier',
      _ => 'Saved on this phone · Delivery pending',
    };

    return Text(
      label,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Color(0xFF455A5E),
      ),
    );
  }
}
