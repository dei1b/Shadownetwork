import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/constants/app_spacing.dart';
import '../../../../core/constants/app_typography.dart';
import '../../../../core/widgets/app_primary_button.dart';
import '../../../../core/widgets/app_text_input.dart';
import '../providers/compose_message_provider.dart';

class ComposeMessagePage extends ConsumerStatefulWidget {
  const ComposeMessagePage({super.key, this.onMessageSent});

  final VoidCallback? onMessageSent;

  @override
  ConsumerState<ComposeMessagePage> createState() => _ComposeMessagePageState();
}

class _ComposeMessagePageState extends ConsumerState<ComposeMessagePage> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onSendPressed() {
    final success = ref.read(composeMessageProvider.notifier).submitDraft();

    if (!success) {
      return;
    }

    _controller.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Message queued for offline delivery.')),
    );
    widget.onMessageSent?.call();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(composeMessageProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Compose Message', style: AppTypography.titleMedium),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: AppTextInput(
                controller: _controller,
                hintText: 'Type emergency details here...',
                minLines: AppSizes.composeMinLines,
                maxLines: AppSizes.composeMaxLines,
                onChanged: ref
                    .read(composeMessageProvider.notifier)
                    .updateDraft,
              ),
            ),
            if (state.errorText != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                state.errorText!,
                style: AppTypography.caption.copyWith(color: AppColors.danger),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            AppPrimaryButton(
              label: 'Send Offline',
              icon: Icons.send,
              onPressed: _onSendPressed,
            ),
          ],
        ),
      ),
    );
  }
}
