import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/action_feedback.dart';
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
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ExpansionTile(
            leading: const Icon(Icons.tune_rounded),
            title: const Text('Advanced'),
            children: [
              if (canUseFieldTest)
                const _FieldTestSettings()
              else
                const ListTile(
                  title: Text('Field test tools require phone approval.'),
                ),
            ],
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
      return ListTile(
        title: const Text('Could not load field test settings.'),
        trailing: TextButton(
          onPressed: () => ref.invalidate(fieldTestToolsEnabledProvider),
          child: const Text('Retry'),
        ),
      );
    }
    return Column(
      children: [
        SwitchListTile(
          title: const Text('Field test tools'),
          subtitle: Text(
            recording
                ? 'Stop the active recording before turning this off.'
                : 'Record and share SOS delivery test results.',
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
        if (enabled)
          ListTile(
            leading: const Icon(Icons.science_outlined),
            title: const Text('Open SOS field test'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).pushNamed('/validation'),
          ),
      ],
    );
  }
}
