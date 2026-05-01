import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_spacing.dart';
import '../../../../core/constants/app_typography.dart';
import '../providers/connection_status_provider.dart';
import '../widgets/connection_status_card.dart';

class ConnectionStatusPage extends ConsumerWidget {
  const ConnectionStatusPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionStatusProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Connection Status', style: AppTypography.titleMedium),
            const SizedBox(height: AppSpacing.md),
            ConnectionStatusCard(status: status),
            const SizedBox(height: AppSpacing.md),
            Text(
              'If no peers are found, keep Bluetooth enabled and move to an open area.',
              style: AppTypography.caption,
            ),
          ],
        ),
      ),
    );
  }
}
