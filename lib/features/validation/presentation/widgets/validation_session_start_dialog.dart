import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/validation_run_identity.dart';
import '../pages/validation_run_scanner_page.dart';

class ValidationSessionInput {
  const ValidationSessionInput({
    required this.name,
    required this.environment,
    required this.notes,
    required this.testRunId,
  });
  final String name;
  final String environment;
  final String notes;
  final String testRunId;
}

Future<ValidationSessionInput?> showValidationSessionStartDialog(
  BuildContext context, {
  String? initialRunCode,
  Future<String?> Function(BuildContext)? scanRunCode,
}) => showDialog<ValidationSessionInput>(
  context: context,
  builder: (_) => ValidationSessionStartDialog(
    initialRunCode: initialRunCode,
    scanRunCode: scanRunCode ?? showValidationRunScanner,
  ),
);

class ValidationSessionStartDialog extends ConsumerStatefulWidget {
  const ValidationSessionStartDialog({
    super.key,
    this.initialRunCode,
    required this.scanRunCode,
  });
  final String? initialRunCode;
  final Future<String?> Function(BuildContext) scanRunCode;
  @override
  ConsumerState<ValidationSessionStartDialog> createState() =>
      _ValidationSessionStartDialogState();
}

class _ValidationSessionStartDialogState
    extends ConsumerState<ValidationSessionStartDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _notes = TextEditingController();
  late final _code = TextEditingController(text: widget.initialRunCode);
  String _environment = 'Outdoor field test';
  bool _scanning = false;
  String? _scanError;

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanError = null;
    });
    try {
      final code = await widget.scanRunCode(context);
      if (!mounted) return;
      if (code != null) _code.text = ValidationRunIdentity.normalizeCode(code);
    } catch (_) {
      if (mounted) {
        setState(
          () => _scanError = 'Unable to scan run QR. Enter the code manually.',
        );
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Start validation session'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                key: const ValueKey('validation-session-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Session name'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a session name.'
                    : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                key: const ValueKey('validation-run-code'),
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Run code',
                  hintText: 'PANABO-2026-001',
                  helperText:
                      'Use the same code on every participating rescuer.',
                  helperMaxLines: 3,
                  errorMaxLines: 4,
                ),
                validator: (value) {
                  try {
                    ValidationRunIdentity.normalizeCode(value ?? '');
                    return null;
                  } on FormatException catch (error) {
                    return error.message;
                  }
                },
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: _scanning
                        ? null
                        : () =>
                              _code.text = ValidationRunIdentity.generateCode(),
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('Generate code'),
                  ),
                  TextButton.icon(
                    onPressed: _scanning ? null : _scan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan run QR'),
                  ),
                ],
              ),
              if (_scanError != null)
                Text(
                  _scanError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: _environment,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Test environment',
                ),
                items:
                    const [
                          'Outdoor field test',
                          'Indoor field test',
                          'Mixed indoor/outdoor',
                          'Laboratory simulation',
                        ]
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(
                              value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                onChanged: (value) {
                  if (value != null) setState(() => _environment = value);
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                key: const ValueKey('validation-session-notes'),
                controller: _notes,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _scanning
            ? null
            : () {
                if (!_form.currentState!.validate()) return;
                Navigator.of(context).pop(
                  ValidationSessionInput(
                    name: _name.text.trim(),
                    environment: _environment,
                    notes: _notes.text.trim(),
                    testRunId: ValidationRunIdentity.normalizeCode(_code.text),
                  ),
                );
              },
        child: const Text('Start recording'),
      ),
    ],
  );
}
