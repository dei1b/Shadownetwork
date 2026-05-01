import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_spacing.dart';
import '../../../../core/constants/app_typography.dart';
import '../providers/connection_status_provider.dart';

class ConnectionStatusCard extends StatelessWidget {
  const ConnectionStatusCard({super.key, required this.status});

  final ConnectionStatusViewModel status;

  (String label, Color color) _statusPresentation() {
    switch (status.connectionState) {
      case PeerConnectionState.connected:
        return ('Connected', AppColors.success);
      case PeerConnectionState.discovering:
        return ('Discovering Peers', AppColors.warning);
      case PeerConnectionState.disconnected:
        return ('Disconnected', AppColors.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    final presentation = _statusPresentation();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Mesh Status', style: AppTypography.titleMedium),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Icon(Icons.circle, size: AppSpacing.md, color: presentation.$2),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(presentation.$1, style: AppTypography.bodyMedium),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Peers: ${status.connectedPeers}',
              style: AppTypography.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Updated: ${status.lastUpdated.hour.toString().padLeft(2, '0')}:${status.lastUpdated.minute.toString().padLeft(2, '0')}',
              style: AppTypography.caption,
            ),
            if (status.errorText != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                status.errorText!,
                style: AppTypography.caption.copyWith(color: AppColors.danger),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
