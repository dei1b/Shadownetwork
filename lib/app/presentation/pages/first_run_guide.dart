import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../data/first_run_guide_store.dart';
import 'startup_splash_page.dart';

class FirstRunGuideGate extends StatefulWidget {
  const FirstRunGuideGate({
    super.key,
    required this.shouldShow,
    required this.child,
  });

  final Future<bool> shouldShow;
  final Widget child;

  @override
  State<FirstRunGuideGate> createState() => _FirstRunGuideGateState();
}

class _FirstRunGuideGateState extends State<FirstRunGuideGate> {
  static const _steps = [
    (
      icon: Icons.sos_rounded,
      title: 'Send an SOS',
      body:
          'On Home, tap Send SOS Message. Choose what happened, check the '
          'location, and send your alert. You can broadcast an SOS before '
          'your phone is registered.',
    ),
    (
      icon: Icons.device_hub_rounded,
      title: 'Nearby phones pass it on',
      body:
          'Keep Bluetooth and Wi-Fi on and allow nearby-device access. '
          'ShadowNetwork can pass messages between phones without mobile data. '
          'If nobody is in range, your message waits on your phone.',
    ),
    (
      icon: Icons.map_outlined,
      title: 'Use the Panabo offline map',
      body:
          'Open Map to view the built-in Panabo map without internet. '
          'Turn on location and allow access to see where you are.',
    ),
    (
      icon: Icons.qr_code_2_rounded,
      title: 'Register with your barangay',
      body:
          'Open Phone Registration, save your details, and show your '
          'registration code to the barangay admin. Then scan the approval '
          'code the admin gives you.',
    ),
  ];

  int _step = 0;
  bool _saving = false;
  bool _finished = false;

  Future<void> _finish() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await FirstRunGuideStore.complete();
    } catch (error) {
      debugPrint('First-run guide completion failed: $error');
    }
    if (mounted) setState(() => _finished = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_finished) return widget.child;
    return FutureBuilder<bool>(
      future: widget.shouldShow,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const StartupSplashPage();
        }
        return snapshot.data == true ? _buildGuide(context) : widget.child;
      },
    );
  }

  Widget _buildGuide(BuildContext context) {
    final theme = Theme.of(context);
    final step = _steps[_step];
    final progress = 'Step ${_step + 1} of ${_steps.length}';
    final isLast = _step == _steps.length - 1;
    return PopScope(
      canPop: _step == 0 && !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step > 0 && !_saving) setState(() => _step--);
      },
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: (constraints.maxHeight - 48).clamp(
                        0.0,
                        double.infinity,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'ShadowNetwork',
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                            TextButton(
                              onPressed: _saving ? null : _finish,
                              child: const Text('Skip'),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 32),
                          child: Semantics(
                            liveRegion: true,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  step.icon,
                                  size: 68,
                                  color: _step == 0
                                      ? AppColors.danger
                                      : theme.colorScheme.primary,
                                ),
                                const SizedBox(height: 20),
                                Semantics(
                                  header: true,
                                  child: Text(
                                    step.title,
                                    style: theme.textTheme.headlineLarge,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  step.body,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(progress, style: theme.textTheme.bodySmall),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: (_step + 1) / _steps.length,
                              borderRadius: BorderRadius.circular(4),
                              semanticsLabel: 'Guide progress',
                            ),
                            const SizedBox(height: 20),
                            ElevatedButton(
                              onPressed: _saving
                                  ? null
                                  : isLast
                                  ? _finish
                                  : () => setState(() => _step++),
                              child: Text(isLast ? 'Get started' : 'Next'),
                            ),
                            if (_step > 0)
                              TextButton(
                                onPressed: _saving
                                    ? null
                                    : () => setState(() => _step--),
                                child: const Text('Back'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
