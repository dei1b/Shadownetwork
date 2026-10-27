import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../domain/services/validation_run_identity.dart';

Future<void> showValidationRunQrDialog(
  BuildContext context, {
  required String testRunId,
}) => showDialog<void>(
  context: context,
  builder: (_) => _RunQrDialog(testRunId: testRunId),
);

class _RunQrDialog extends StatelessWidget {
  const _RunQrDialog({required this.testRunId});
  final String testRunId;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Share validation run'),
    content: SizedBox(
      width: 320,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(
                data: ValidationRunIdentity.encodeQr(testRunId),
                size: 220,
                backgroundColor: Colors.white,
                semanticsLabel: 'Validation run QR',
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              testRunId,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            const Text(
              'Other rescuers can scan this QR or enter the code. It groups test records; it does not grant device trust.',
            ),
            const SizedBox(height: 12),
            ValidationRunCopyButton(testRunId: testRunId),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  );
}

class ValidationRunCopyButton extends ConsumerStatefulWidget {
  const ValidationRunCopyButton({super.key, required this.testRunId});
  final String testRunId;
  @override
  ConsumerState<ValidationRunCopyButton> createState() =>
      _ValidationRunCopyButtonState();
}

class _ValidationRunCopyButtonState
    extends ConsumerState<ValidationRunCopyButton> {
  String? _feedback;
  Future<void> _copy() async {
    String message;
    try {
      await Clipboard.setData(ClipboardData(text: widget.testRunId));
      message = 'Run code copied';
    } catch (_) {
      message = 'Unable to copy run code';
    }
    if (mounted) setState(() => _feedback = message);
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextButton.icon(
        onPressed: _copy,
        icon: const Icon(Icons.copy_outlined),
        label: const Text('Copy run code'),
      ),
      if (_feedback != null) Text(_feedback!, semanticsLabel: _feedback),
    ],
  );
}

class ValidationRunIdentityPanel extends StatelessWidget {
  const ValidationRunIdentityPanel({
    super.key,
    required this.testRunId,
    this.share = true,
  });
  final String? testRunId;
  final bool share;
  @override
  Widget build(BuildContext context) {
    final code = testRunId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TEST RUN',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            code ?? 'No run ID (legacy)',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (code != null && share)
            Wrap(
              spacing: 8,
              children: [
                ValidationRunCopyButton(testRunId: code),
                TextButton.icon(
                  onPressed: () =>
                      showValidationRunQrDialog(context, testRunId: code),
                  icon: const Icon(Icons.qr_code),
                  label: const Text('Show run QR'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
