import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadownetwork/core/widgets/action_feedback.dart';

import '../../../trust/domain/entities/device_trust_status.dart';
import '../../domain/entities/message_moderation_status.dart';
import '../../domain/entities/peer_location_share.dart';
import '../../domain/entities/sos_message.dart';
import '../providers/sos_clock_provider.dart';
import '../utils/sos_timing_labels.dart';
import 'sos_send_status.dart';

/// Opens SOS details and returns true when the caller should update its status.
/// The modal pops with a null result before [onShowOnMap] runs. Use the
/// callback to focus the map on [message]'s coordinates.
Future<bool?> showSosDetailSheet(
  BuildContext context, {
  required SosMessage message,
  VoidCallback? onMessageSender,
  VoidCallback? onShowOnMap,
  String? ownSenderLabel,
  bool canUpdateResponse = false,
  bool canUpdateArchive = false,
  bool showTechnicalDetails = true,
  String? locationSummary,
}) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.white,
  showDragHandle: true,
  builder: (sheetContext) => SosDetailSheet(
    message: message,
    ownSenderLabel: ownSenderLabel,
    showTechnicalDetails: showTechnicalDetails,
    locationSummary: locationSummary,
    onShowOnMap: onShowOnMap == null
        ? null
        : () {
            Navigator.of(sheetContext).pop();
            onShowOnMap();
          },
    onUpdateArchive: canUpdateArchive
        ? () => Navigator.of(sheetContext).pop(true)
        : null,
    onUpdateResponse: canUpdateResponse
        ? () => Navigator.of(sheetContext).pop(true)
        : null,
    onMessageSender: onMessageSender == null
        ? null
        : () {
            Navigator.of(sheetContext).pop();
            onMessageSender();
          },
  ),
);

class SosDetailSheet extends StatelessWidget {
  const SosDetailSheet({
    super.key,
    required this.message,
    this.onMessageSender,
    this.onShowOnMap,
    this.ownSenderLabel,
    this.onUpdateResponse,
    this.onUpdateArchive,
    this.showTechnicalDetails = true,
    this.locationSummary,
  });

  final SosMessage message;
  final VoidCallback? onMessageSender;
  final VoidCallback? onShowOnMap;
  final String? ownSenderLabel;
  final VoidCallback? onUpdateResponse;
  final VoidCallback? onUpdateArchive;
  final bool showTechnicalDetails;
  final String? locationSummary;

  static const _actionStyle = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(0, 48)),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.padded,
  );

  @override
  Widget build(BuildContext context) {
    final latitude = message.latitude;
    final longitude = message.longitude;
    final accuracy = message.gpsAccuracyMeters;
    final hasLocation =
        latitude != null &&
        longitude != null &&
        PeerLocationShare.hasValidCoordinates(latitude, longitude);
    final showOnMap = hasLocation ? onShowOnMap : null;
    final isOwn = ownSenderLabel != null;
    final isRevoked = message.trustStatus == DeviceTrustStatus.revoked;
    final showCreatedTime = isOwn && message.receivedAt == null;
    final messageSender = isOwn ? null : onMessageSender;
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
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            'SOS details',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
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
                  _DetailRow(
                    label: 'Sender',
                    value:
                        ownSenderLabel ??
                        message.trustOwnerName ??
                        message.sender.name,
                  ),
                  _DetailRow(
                    label: 'Emergency',
                    value: message.category.label,
                    description: message.body,
                  ),
                  _DetailRow(
                    label: 'Location',
                    value: hasLocation
                        ? (showTechnicalDetails
                              ? '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}'
                              : (locationSummary ?? 'Location attached'))
                        : 'No GPS location attached',
                    description: showTechnicalDetails && hasLocation && accuracy != null
                        ? 'GPS accuracy ±${accuracy.toStringAsFixed(1)} m'
                        : null,
                  ),
                  _DetailRow(
                    label: showCreatedTime ? 'Created time' : 'Received time',
                    value: SosTimingLabels.timestamp(
                      showCreatedTime ? message.createdAt : message.receivedAt,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (showOnMap != null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: _actionStyle,
                        onPressed: showOnMap,
                        icon: const Icon(Icons.location_on_outlined),
                        label: const Text('Show on map'),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  if (messageSender != null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: showOnMap == null
                          ? FilledButton.icon(
                              style: _actionStyle,
                              onPressed: messageSender,
                              icon: const Icon(Icons.chat_bubble_outline),
                              label: const Text('Message sender'),
                            )
                          : OutlinedButton.icon(
                              style: _actionStyle,
                              onPressed: messageSender,
                              icon: const Icon(Icons.chat_bubble_outline),
                              label: const Text('Message sender'),
                            ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  if (message.respondedAt != null)
                    _DetailRow(
                      label: 'Responded',
                      value: SosTimingLabels.timestamp(message.respondedAt),
                    ),
                  if (onUpdateResponse != null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: _actionStyle,
                        onPressed: onUpdateResponse,
                        icon: Icon(
                          message.respondedAt == null
                              ? Icons.check_circle_outline
                              : Icons.unarchive_outlined,
                        ),
                        label: Text(
                          message.respondedAt == null
                              ? 'Mark responded'
                              : 'Restore alert',
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  if (onUpdateArchive != null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: TextButton.icon(
                        style: _actionStyle,
                        onPressed: onUpdateArchive,
                        icon: Icon(
                          message.archivedAt == null
                              ? Icons.archive_outlined
                              : Icons.unarchive_outlined,
                        ),
                        label: Text(
                          message.archivedAt == null
                              ? 'Archive SOS'
                              : 'Restore SOS',
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  if (isOwn) ...[
                    if (!isRevoked) const Text('Created on this phone'),
                    SosSendStatus(message: message),
                  ],
                  if (showTechnicalDetails) ...[
                    const Divider(),
                    _SosDeliveryDetails(
                      message: message,
                      isOwn: isOwn,
                      showCreatedTime: !showCreatedTime,
                      showGpsAccuracy: !hasLocation,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SosDeliveryDetails extends StatelessWidget {
  const _SosDeliveryDetails({
    required this.message,
    required this.isOwn,
    required this.showCreatedTime,
    required this.showGpsAccuracy,
  });

  final SosMessage message;
  final bool isOwn;
  final bool showCreatedTime;
  final bool showGpsAccuracy;

  @override
  Widget build(BuildContext context) {
    final hash = message.messageHash;
    final accuracy = message.gpsAccuracyMeters;
    final isRevoked = message.trustStatus == DeviceTrustStatus.revoked;
    final isSpam = message.moderationStatus == MessageModerationStatus.spam;
    final headingStyle = Theme.of(context).textTheme.titleSmall;

    return ExpansionTile(
      title: const Text('Delivery details'),
      tilePadding: EdgeInsets.zero,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      shape: const Border(),
      collapsedShape: const Border(),
      children: [
        Text('Timing and routing', style: headingStyle),
        if (showCreatedTime)
          _DetailRow(
            label: 'Created time',
            value: SosTimingLabels.timestamp(message.createdAt),
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
        _DetailRow(label: 'Sender device ID', value: message.sender.id),
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
        if (showGpsAccuracy && accuracy != null)
          _DetailRow(
            label: 'GPS accuracy',
            value: '±${accuracy.toStringAsFixed(1)} m',
          ),
        _SosTtlRow(message: message),
        _DetailRow(label: 'Delivery status', value: message.status.name),
        const Divider(),
        Text('Verification and privacy', style: headingStyle),
        if (!isOwn || isRevoked)
          _DetailRow(
            label: 'Trust',
            value: isRevoked
                ? 'Revoked • Quarantine'
                : message.trustStatus.displayLabel,
          ),
        if (!isOwn) ...[
          _DetailRow(label: 'Moderation', value: isSpam ? 'Spam' : 'Normal'),
          if (message.moderationReason != null)
            _DetailRow(
              label: 'Moderation reason',
              value: message.moderationReason!,
            ),
        ],
        _DetailRow(
          label: 'Payload privacy',
          value: message.isEncrypted
              ? 'Targeted • Encrypted'
              : message.recipient != null
              ? 'Targeted • Plaintext (legacy)'
              : 'Broadcast • Plaintext',
        ),
      ],
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
        ActionFeedback.show(
          context,
          'Message hash copied',
          kind: FeedbackKind.success,
        );
      }
    } catch (_) {
      if (context.mounted) {
        ActionFeedback.show(
          context,
          'Unable to copy message hash. Try again.',
          kind: FeedbackKind.error,
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
  const _DetailRow({
    required this.label,
    required this.value,
    this.description,
    this.trailing,
  });
  final String label;
  final String value;
  final String? description;
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
        if (description case final description?)
          SelectableText(description, style: const TextStyle(fontSize: 14)),
      ],
    ),
  );
}
