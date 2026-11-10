import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/widgets/action_feedback.dart';
import '../../data/services/desktop_registration_scan_session.dart';

class WindowsRegistrationScanner extends StatefulWidget {
  const WindowsRegistrationScanner({super.key});

  @override
  State<WindowsRegistrationScanner> createState() =>
      _WindowsRegistrationScannerState();
}

class _WindowsRegistrationScannerState
    extends State<WindowsRegistrationScanner> {
  static const _windowChannel = MethodChannel('shadownetwork/admin_window');

  DesktopRegistrationScanSession? _session;
  bool _opening = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_openBrowser());
  }

  Future<void> _openBrowser() async {
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      var session = _session;
      if (session == null) {
        session = await DesktopRegistrationScanSession.start();
        if (!mounted) {
          await session.close();
          return;
        }
        _session = session;
        unawaited(_receiveScan(session));
      }
      if (!await launchUrl(session.uri, mode: LaunchMode.externalApplication)) {
        throw StateError('Browser did not open');
      }
    } catch (_) {
      if (mounted) {
        _error =
            'Could not open the browser scanner. Try again or use Paste Phone Registration JSON.';
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _receiveScan(DesktopRegistrationScanSession session) async {
    final source = await session.result;
    if (source != null && mounted && ModalRoute.isCurrentOf(context) == true) {
      Navigator.of(context).pop(source);
      // Let the browser handle its successful response and close the tab first.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      try {
        await _windowChannel.invokeMethod<void>('focus');
      } on MissingPluginException {
        // The registration result is already available in the form.
      } on PlatformException {
        // Focus is best effort and does not affect registration.
      }
    }
  }

  @override
  void dispose() {
    final session = _session;
    if (session != null) unawaited(session.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Scan phone QR'),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_opening)
            const Text('Opening the browser camera…')
          else if (_error == null)
            const Text(
              'Allow camera access in your browser and hold the phone’s '
              'registration QR in view. Keep this window open. The details '
              'will fill in here when the code is read.',
            )
          else
            ActionStatus(message: _error!, kind: FeedbackKind.error),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
      if (!_opening)
        OutlinedButton(
          onPressed: _openBrowser,
          child: Text(_error == null ? 'Reopen browser scanner' : 'Try again'),
        ),
    ],
  );
}
