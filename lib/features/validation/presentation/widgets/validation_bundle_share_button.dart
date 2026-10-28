import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/validation_session.dart';
import '../../domain/repositories/validation_bundle_file_gateway.dart';
import '../providers/validation_bundle_export_provider.dart';

class ValidationBundleShareButton extends ConsumerWidget {
  const ValidationBundleShareButton({super.key, required this.session});

  final ValidationSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final legacy = session.testRunId == null;
    final busy = !legacy && ref.watch(validationBundleExportProvider).isLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: legacy || busy ? null : () => _share(context, ref),
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.share_outlined),
          label: Text(busy ? 'PREPARING FILE…' : 'SHARE VALIDATION FILE'),
        ),
        const SizedBox(height: 4),
        Text(
          legacy
              ? 'No run code. Use Copy JSON or Copy CSV.'
              : 'Timing and relay data. Message text and exact locations are excluded.',
          style: const TextStyle(fontSize: 11, color: Color(0xFF6F6A68)),
        ),
      ],
    );
  }

  Future<void> _share(BuildContext context, WidgetRef ref) async {
    String? message;
    try {
      final bundle = await ref
          .read(validationBundleExportProvider.notifier)
          .shareSession(session.id);
      if (bundle != null) message = 'Validation file created.';
    } catch (error) {
      message = switch (error) {
        StateError() => error.message.toString(),
        ValidationBundleShareException() =>
          'Could not open sharing. The file stays saved; try again.',
        PlatformException() =>
          'Could not prepare the validation file. Try again.',
        FileSystemException() =>
          'Could not save the file. Check free space and try again.',
        _ => 'Could not create the validation file. Try again.',
      };
    }
    if (context.mounted && message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
