import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/mobile_ui_tokens.dart';
import '../../../core/widgets/action_feedback.dart';
import '../../../core/widgets/mobile_ui_components.dart';
import '../../../features/trust/presentation/providers/device_access_provider.dart';
import '../../../features/validation/presentation/providers/field_test_settings_provider.dart';
import '../../../features/validation/presentation/providers/validation_session_provider.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(deviceAccessProfileProvider);
    final canUseFieldTest = access.valueOrNull?.canUseFieldTest == true;
    return Scaffold(
      backgroundColor: MobileUiTokens.canvas,
      appBar: buildMobileAppBar(title: 'Settings'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          const MobileSectionLabel('Device & diagnostics'),
          MobileSectionCard(
            padding: EdgeInsets.zero,
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
                splashColor: MobileUiTokens.redTint.withValues(alpha: 0.4),
              ),
              child: ExpansionTile(
                shape: const Border(),
                collapsedShape: const Border(),
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                iconColor: MobileUiTokens.brandRed,
                collapsedIconColor: MobileUiTokens.mutedInk,
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: MobileUiTokens.redTint,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: const ExcludeSemantics(
                    child: Icon(
                      Icons.tune_rounded,
                      size: 20,
                      color: MobileUiTokens.brandRed,
                    ),
                  ),
                ),
                title: const Text('Advanced', style: MobileUiTokens.bodyStrong),
                subtitle: const Text(
                  'Backup registration and field test tools',
                  style: MobileUiTokens.subtitle,
                ),
                children: [
                  const MobileTileDivider(),
                  MobileActionTile(
                    icon: Icons.qr_code_scanner_outlined,
                    title: 'Backup registration',
                    subtitle: 'Get or update access with a campus admin',
                    onTap: () =>
                        Navigator.of(context).pushNamed('/trust-bundle'),
                  ),
                  const MobileTileDivider(indent: 68),
                  if (canUseFieldTest)
                    const _FieldTestSettings()
                  else
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: MobileStatusBanner(
                        tone: MobileStatusTone.info,
                        icon: Icons.lock_outline_rounded,
                        message: 'Field test tools require phone approval.',
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldTestSettings extends ConsumerWidget {
  const _FieldTestSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preference = ref.watch(fieldTestToolsEnabledProvider);
    final enabled = preference.valueOrNull == true;
    final recording =
        enabled &&
        ref.watch(
          validationSessionProvider.select(
            (state) => state.valueOrNull?.activeSession != null,
          ),
        );
    if (preference.hasError) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const MobileStatusBanner(
              tone: MobileStatusTone.warning,
              message: 'Could not load field test settings.',
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              style: MobileButtonStyles.secondaryOutlined,
              onPressed: () => ref.invalidate(fieldTestToolsEnabledProvider),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 6,
          ),
          activeThumbColor: MobileUiTokens.brandRed,
          activeTrackColor: MobileUiTokens.redBorder,
          title: const Text(
            'Field test tools',
            style: MobileUiTokens.bodyStrong,
          ),
          subtitle: Text(
            recording
                ? 'Stop the active recording before turning this off.'
                : 'Record and share SOS delivery test results.',
            style: MobileUiTokens.subtitle,
          ),
          value: enabled,
          onChanged: preference.isLoading || recording
              ? null
              : (value) async {
                  try {
                    await ref
                        .read(fieldTestToolsEnabledProvider.notifier)
                        .setEnabled(value);
                  } catch (_) {
                    if (context.mounted) {
                      ActionFeedback.show(
                        context,
                        'Could not save the setting. Try again.',
                        kind: FeedbackKind.error,
                      );
                    }
                  }
                },
        ),
        if (enabled) ...[
          const MobileTileDivider(indent: 68),
          MobileActionTile(
            icon: Icons.science_outlined,
            title: 'Open SOS field test',
            subtitle: 'Start, record, or export a field test run',
            onTap: () => Navigator.of(context).pushNamed('/validation'),
          ),
        ],
      ],
    );
  }
}
