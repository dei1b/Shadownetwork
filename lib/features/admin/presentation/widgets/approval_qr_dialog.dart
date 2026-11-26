import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shadownetwork/core/widgets/action_feedback.dart';

import '../../../trust/domain/services/multi_frame_qr.dart';

Future<void> showApprovalQrDialog(
  BuildContext context, {
  required String title,
  required String payloadJson,
  String? copyJson,
  String subtitle =
      'Open the approval scanner on the phone and fit the whole code in view.',
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => ApprovalQrDialog(
      title: title,
      payloadJson: payloadJson,
      copyJson: copyJson ?? payloadJson,
      subtitle: subtitle,
    ),
  );
}

class ApprovalQrDialog extends StatefulWidget {
  const ApprovalQrDialog({
    super.key,
    required this.title,
    required this.payloadJson,
    required this.copyJson,
    this.subtitle =
        'Open the approval scanner on the phone and fit the whole code in view.',
  });

  final String title;
  final String payloadJson;
  final String copyJson;
  final String subtitle;

  @override
  State<ApprovalQrDialog> createState() => _ApprovalQrDialogState();
}

class _ApprovalQrDialogState extends State<ApprovalQrDialog> {
  late final List<String> _frames = MultiFrameQrCodec.encode(
    _compactJson(widget.payloadJson),
  );
  int _frameIndex = 0;
  bool _autoCycle = true;
  Timer? _timer;

  static String _compactJson(String source) {
    try {
      return jsonEncode(jsonDecode(source));
    } catch (_) {
      return source;
    }
  }

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  void _syncTimer() {
    _timer?.cancel();
    if (_frames.length > 1 && _autoCycle) {
      _timer = Timer.periodic(const Duration(milliseconds: 1400), (_) {
        if (!mounted) return;
        setState(() => _frameIndex = (_frameIndex + 1) % _frames.length);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentData = _frames[_frameIndex];
    final isMultiFrame = _frames.length > 1;
    final qr = QrCode.fromData(
      data: currentData,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(maxWidth: 840),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              isMultiFrame
                  ? 'Directory split across ${_frames.length} QR frames. Keep scanning on the phone until all frames complete.'
                  : widget.subtitle,
              textAlign: TextAlign.center,
            ),
            if (isMultiFrame) ...[
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Frame ${_frameIndex + 1} of ${_frames.length}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  IconButton(
                    tooltip: 'Previous frame',
                    onPressed: () {
                      setState(() {
                        _autoCycle = false;
                        _frameIndex =
                            (_frameIndex - 1 + _frames.length) % _frames.length;
                      });
                      _syncTimer();
                    },
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  IconButton(
                    tooltip: 'Next frame',
                    onPressed: () {
                      setState(() {
                        _autoCycle = false;
                        _frameIndex = (_frameIndex + 1) % _frames.length;
                      });
                      _syncTimer();
                    },
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      setState(() => _autoCycle = !_autoCycle);
                      _syncTimer();
                    },
                    icon: Icon(
                      _autoCycle
                          ? Icons.pause_circle_outline
                          : Icons.play_circle_outline,
                      size: 18,
                    ),
                    label: Text(_autoCycle ? 'Pause' : 'Auto-cycle'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Keep 4 white quiet-zone modules on each side aligned to half pixels.
                  final modules = qr.moduleCount + 8;
                  final tile =
                      (constraints.biggest.shortestSide * 2 / modules)
                          .floorToDouble() /
                      2;
                  if (tile == 0) return const SizedBox.shrink();
                  return Center(
                    child: QrImageView.withQr(
                      qr: qr,
                      size: modules * tile,
                      padding: EdgeInsets.all(4 * tile),
                      backgroundColor: Colors.white,
                      semanticsLabel: isMultiFrame
                          ? 'Phone approval QR code frame ${_frameIndex + 1} of ${_frames.length}'
                          : 'Phone approval QR code',
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
                FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: widget.copyJson),
                    );
                    if (context.mounted) {
                      Navigator.of(context).pop();
                      ActionFeedback.show(
                        context,
                        'Offline trust bundle copied to clipboard.',
                      );
                    }
                  },
                  icon: const Icon(Icons.content_copy_rounded),
                  label: const Text('Copy JSON'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
