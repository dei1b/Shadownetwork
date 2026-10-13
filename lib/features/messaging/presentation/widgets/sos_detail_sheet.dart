import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/message_moderation_status.dart';
import '../../domain/entities/sos_message.dart';
import '../../../trust/domain/entities/device_trust_status.dart';
import '../providers/sos_clock_provider.dart';
import '../utils/sos_timing_labels.dart';
import 'sos_receipt_summary.dart';

Future<void> showSosDetailSheet(
  BuildContext context, {
  required SosMessage message,
  required VoidCallback onMessageSender,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.white,
  showDragHandle: true,
  builder: (sheetContext) => SosDetailSheet(
    message: message,
    onMessageSender: () {
      Navigator.of(sheetContext).pop();
      onMessageSender();
    },
  ),
);

class SosDetailSheet extends StatelessWidget {
  const SosDetailSheet({
    super.key,
    required this.message,
    required this.onMessageSender,
  });

  final SosMessage message;
  final VoidCallback onMessageSender;

  @override
  Widget build(BuildContext context) {
    final hash = message.messageHash;
    final isRevoked = message.trustStatus == DeviceTrustStatus.revoked;
    final isSpam = message.moderationStatus == MessageModerationStatus.spam;
    return ScaffoldMessenger(
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.88,
          ),
          child: Scaffold(
            backgroundColor: Colors.white,
            body: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'SOS details',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF1F1F1F),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close SOS details',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Text(
                    message.category.label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFE83C3D),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    message.body,
                    style: const TextStyle(fontSize: 15),
                  ),
                  const SizedBox(height: 14),
                  SosReceiptSummary(message: message),
                  const SizedBox(height: 14),
                  const Divider(),
                  const Text(
                    'TIMING & ROUTING',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  _DetailRow(
                    label: 'Created time',
                    value: SosTimingLabels.timestamp(message.createdAt),
                  ),
                  _DetailRow(
                    label: 'Received time',
                    value: SosTimingLabels.timestamp(message.receivedAt),
                  ),
                  _DetailRow(
                    label: 'Propagation',
                    value: SosTimingLabels.propagation(message),
                  ),
                  if (SosTimingLabels.hasClockMismatch(message))
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        'The receipt precedes creation. Check the phones’ clocks; this is not a valid travel-time measurement.',
                        style: TextStyle(color: Color(0xFF9B341E)),
                      ),
                    ),
                  _DetailRow(
                    label: 'Hop count',
                    value: SosTimingLabels.hops(message.hopCount),
                  ),
                  _DetailRow(
                    label: 'Last transport',
                    value:
                        SosTimingLabels.transport(message.receivedTransport) ??
                        'Not recorded',
                  ),
                  _DetailRow(
                    label: 'Sender',
                    value:
                        '${message.trustOwnerName ?? message.sender.name}\n${message.sender.id}',
                  ),
                  _DetailRow(
                    label: 'Last relay peer',
                    value: message.receivedFromPeerId ?? 'Not recorded',
                  ),
                  _DetailRow(
                    label: 'Message hash',
                    value: hash == null || hash.isEmpty
                        ? 'Not recorded'
                        : SosTimingLabels.shortHash(hash),
                    trailing: hash == null || hash.isEmpty
                        ? null
                        : _CopyHashButton(hash: hash),
                  ),
                  _DetailRow(
                    label: 'GPS accuracy',
                    value: message.gpsAccuracyMeters == null
                        ? 'Not recorded'
                        : '±${message.gpsAccuracyMeters!.toStringAsFixed(1)} m',
                  ),
                  _SosTtlRow(message: message),
                  _DetailRow(
                    label: 'Delivery status',
                    value: message.status.name,
                  ),
                  const Divider(),
                  const Text(
                    'TRUST & MODERATION',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  _DetailRow(
                    label: 'Trust',
                    value: isRevoked
                        ? 'Revoked • Quarantine'
                        : message.trustStatus.displayLabel,
                  ),
                  _DetailRow(
                    label: 'Moderation',
                    value: isSpam ? 'Spam' : 'Normal',
                  ),
                  if (message.moderationReason != null)
                    _DetailRow(
                      label: 'Moderation reason',
                      value: message.moderationReason!,
                    ),
                  _DetailRow(
                    label: 'Payload privacy',
                    value: message.isEncrypted
                        ? 'Targeted • Encrypted'
                        : message.recipient != null
                        ? 'Targeted • Plaintext (legacy)'
                        : 'Broadcast • Plaintext',
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: onMessageSender,
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Message sender'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CopyHashButton extends StatelessWidget {
  const _CopyHashButton({required this.hash});
  final String hash;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Copy full message hash',
    icon: const Icon(Icons.copy_outlined, size: 20),
    onPressed: () => _copyHash(context),
  );

  Future<void> _copyHash(BuildContext context) async {
    try {
      await Clipboard.setData(ClipboardData(text: hash));
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Message hash copied')));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to copy message hash')),
        );
      }
    }
  }
}

class _SosTtlRow extends ConsumerWidget {
  const _SosTtlRow({required this.message});
  final SosMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _DetailRow(
    label: 'TTL',
    value: SosTimingLabels.ttl(message, ref.watch(sosClockProvider)),
  );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.trailing});
  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ],
    ),
  );
}
