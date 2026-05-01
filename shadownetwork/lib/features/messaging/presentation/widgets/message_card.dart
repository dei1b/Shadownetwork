import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_spacing.dart';
import '../../../../core/constants/app_typography.dart';
import '../../domain/entities/message.dart';

class MessageCard extends StatelessWidget {
  const MessageCard({super.key, required this.message});

  final Message message;

  String _formatLocation() {
    if (message.latitude == null || message.longitude == null) {
      return 'Location unavailable';
    }

    final lat = message.latitude!.toStringAsFixed(4);
    final lng = message.longitude!.toStringAsFixed(4);
    return 'GPS $lat, $lng';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    message.senderName,
                    style: AppTypography.titleMedium,
                  ),
                ),
                Text(
                  '${message.sentAt.hour.toString().padLeft(2, '0')}:${message.sentAt.minute.toString().padLeft(2, '0')}',
                  style: AppTypography.caption,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(message.body, style: AppTypography.bodyMedium),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: Text(_formatLocation(), style: AppTypography.caption),
                ),
                if (message.isRelayed)
                  Text(
                    'RELAYED',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.warning,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
