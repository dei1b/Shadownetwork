import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/conversation.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/entities/sos_message.dart';
import '../../../security/data/services/message_encryption_service.dart';
import '../../../trust/domain/entities/device_trust_status.dart';
import '../providers/local_messaging_providers.dart';
import '../providers/relay_runtime_provider.dart';

class ConversationPage extends ConsumerStatefulWidget {
  const ConversationPage({
    required this.conversation,
    this.linkedSosMessage,
    super.key,
  });

  final Conversation conversation;
  final SosMessage? linkedSosMessage;

  @override
  ConsumerState<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends ConsumerState<ConversationPage> {
  final TextEditingController _composer = TextEditingController();
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(markConversationReadProvider)(widget.conversation.id);
    });
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _composer.text.trim();
    if (body.isEmpty || _isSending) {
      return;
    }
    setState(() => _isSending = true);
    try {
      await ref.read(sendChatMessageProvider)(widget.conversation, body);
      _composer.clear();
      await ref.read(relayRuntimeProvider.notifier).syncNow(force: true);
      ref.invalidate(chatMessagesProvider(widget.conversation.id));
    } on MessageEncryptionException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatMessagesProvider(widget.conversation.id));
    final remote = widget.conversation.remotePeer;
    final isRevoked =
        widget.conversation.latestTrustStatus == DeviceTrustStatus.revoked;
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF202020),
        elevation: 0,
        titleSpacing: 4,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              remote.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            Text(
              '${(widget.conversation.latestTrustStatus ?? DeviceTrustStatus.unknown).displayLabel} - ${remote.isConnected ? 'Connected nearby' : 'Offline relay available'}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: remote.isConnected
                    ? const Color(0xFF16833C)
                    : const Color(0xFF717173),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (isRevoked)
            Container(
              width: double.infinity,
              color: const Color(0xFF7D1A1A),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: const Text(
                'QUARANTINED: This sender is revoked. Reply and automatic relay are disabled.',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          if (widget.linkedSosMessage != null)
            _LinkedSosBanner(message: widget.linkedSosMessage!),
          Expanded(
            child: messages.when(
              data: (items) => items.isEmpty
                  ? const Center(
                      child: Text(
                        'No messages yet',
                        style: TextStyle(color: Color(0xFF717173)),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final message = items[index];
                        final outgoing =
                            message.sender.id ==
                            widget.conversation.localPeerId;
                        return _ChatBubble(
                          text: message.body,
                          outgoing: outgoing,
                          status: message.status,
                          createdAt: message.createdAt,
                          trustStatus: message.trustStatus,
                        );
                      },
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) =>
                  const Center(child: Text('Unable to load thread.')),
            ),
          ),
          Container(
            color: Colors.white,
            padding: EdgeInsets.fromLTRB(
              12,
              10,
              12,
              10 + MediaQuery.paddingOf(context).bottom,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _composer,
                    enabled: !isRevoked,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: isRevoked
                          ? 'Replies disabled for revoked sender'
                          : 'Message ${remote.name}',
                      filled: true,
                      fillColor: const Color(0xFFF3F3F3),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send message',
                  onPressed: _isSending || isRevoked ? null : _send,
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFFE83C3D),
                    minimumSize: const Size(48, 48),
                  ),
                  icon: _isSending
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkedSosBanner extends StatelessWidget {
  const _LinkedSosBanner({required this.message});

  final SosMessage message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFEEEE),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.sos_rounded, color: Color(0xFFE83C3D), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Linked SOS alert',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                Text(
                  '${message.trustStatus.displayLabel} ${message.trustRole ?? 'sender'}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: _trustColor(message.trustStatus),
                  ),
                ),
                Text(
                  message.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.text,
    required this.outgoing,
    required this.status,
    required this.createdAt,
    required this.trustStatus,
  });

  final String text;
  final bool outgoing;
  final MessageStatus status;
  final DateTime createdAt;
  final DeviceTrustStatus trustStatus;

  @override
  Widget build(BuildContext context) {
    final timeStr = _formatTime(createdAt);
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 290),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: outgoing ? const Color(0xFFE83C3D) : Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                text,
                style: TextStyle(
                  fontSize: 14,
                  color: outgoing ? Colors.white : const Color(0xFF202020),
                ),
              ),
              const SizedBox(height: 6),
              if (!outgoing) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    trustStatus.displayLabel.toUpperCase(),
                    style: TextStyle(
                      color: _trustColor(trustStatus),
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    timeStr,
                    style: TextStyle(
                      fontSize: 10,
                      color: outgoing
                          ? Colors.white.withValues(alpha: 0.86)
                          : const Color(0xFF717173),
                    ),
                  ),
                  if (outgoing) ...[
                    const SizedBox(width: 4),
                    Text(
                      '• ${_statusText(status)}',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.86),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime dateTime) {
    final localTime = dateTime.toLocal();
    final hour = localTime.hour;
    final minute = localTime.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    return '$displayHour:$minute $period';
  }

  static String _statusText(MessageStatus status) => switch (status) {
    MessageStatus.queued => 'Queued offline',
    MessageStatus.sending => 'Sending',
    MessageStatus.sent => 'Relayed',
    MessageStatus.delivered => 'Delivered',
    MessageStatus.failed => 'Failed',
    _ => status.name,
  };
}

Color _trustColor(DeviceTrustStatus status) => switch (status) {
  DeviceTrustStatus.approved => const Color(0xFF1E6B3B),
  DeviceTrustStatus.unknown => const Color(0xFF8A6200),
  DeviceTrustStatus.revoked => const Color(0xFF861A1A),
};
