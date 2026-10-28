import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/admin_recovery_provider.dart';

class AdminRecoveryPanel extends ConsumerStatefulWidget {
  const AdminRecoveryPanel({
    super.key,
    required this.onSaveBackup,
    required this.onReadBackup,
  });
  final Future<bool> Function(String source) onSaveBackup;
  final Future<String?> Function() onReadBackup;

  @override
  ConsumerState<AdminRecoveryPanel> createState() => _AdminRecoveryPanelState();
}

class _AdminRecoveryPanelState extends ConsumerState<AdminRecoveryPanel> {
  bool _busy = false;
  String? _message;
  bool _error = false;

  Future<void> _perform(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final message = await action();
      if (mounted) {
        setState(() {
          _message = message;
          _error = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = error is StateError
              ? error.message.toString()
              : error is FormatException
              ? error.message
              : 'Unable to complete this operation. Check the file, password and available storage, then try again.';
          _error = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _create() => _perform(() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create administrator identity?'),
        content: const Text(
          'This computer will create or reconnect its protected signing identity. A new identity cannot replace the administrator already trusted by existing phones. Restore the original backup if you have one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create identity'),
          ),
        ],
      ),
    );
    if (confirmed != true) return null;
    await ref.read(adminRecoveryProvider.notifier).initializeIdentity();
    return 'Administrator identity ready. Save an encrypted backup before publishing trust bundles.';
  });

  Future<void> _backup() => _perform(() async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _PasswordDialog(confirm: true),
    );
    if (password == null) return null;
    final source = await ref
        .read(adminRecoveryProvider.notifier)
        .createBackup(password);
    if (!mounted) return null;
    final saved = await widget.onSaveBackup(source);
    return saved
        ? 'Encrypted administrator backup saved.'
        : 'Backup was not saved.';
  });

  Future<void> _restore() => _perform(() async {
    final source = await widget.onReadBackup();
    if (source == null || !mounted) return null;
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _PasswordDialog(confirm: false),
    );
    if (password == null) return null;
    await ref
        .read(adminRecoveryProvider.notifier)
        .restoreBackup(source, password);
    return 'Administrator backup restored. Review your devices before publishing a new trust bundle.';
  });

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(adminRecoveryProvider);
    final status = identity.valueOrNull;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Backup & recovery',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 12),
        const Text(
          'Your administrator registry is saved on this Windows account. Signing keys are protected by Windows. Keep an encrypted backup on a separate drive and keep its password safe.',
        ),
        const SizedBox(height: 16),
        if (identity.isLoading) const LinearProgressIndicator(),
        if (identity.hasError) ...[
          const Text(
            'The saved registry and protected signing identity could not be opened together. No replacement identity was created. Restore the matching original backup or retry.',
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => ref.read(adminRecoveryProvider.notifier).refresh(),
            child: const Text('Retry identity check'),
          ),
        ],
        if (status != null) ...[
          Text(
            status.hasIdentity
                ? 'Administrator identity ready'
                : 'Administrator setup required',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (status.fingerprint != null)
            SelectableText('Identity fingerprint: ${status.fingerprint}'),
          Text('Latest reserved trust bundle version: ${status.bundleVersion}'),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            if (status != null && !status.hasIdentity)
              FilledButton(
                onPressed: _busy ? null : _create,
                child: const Text('Create administrator identity'),
              ),
            OutlinedButton.icon(
              onPressed: _busy || status?.hasIdentity != true ? null : _backup,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save encrypted backup'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _restore,
              icon: const Icon(Icons.restore),
              label: const Text('Restore encrypted backup'),
            ),
          ],
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: LinearProgressIndicator(),
          ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              _message!,
              style: TextStyle(
                color: _error ? Theme.of(context).colorScheme.error : null,
              ),
            ),
          ),
        const SizedBox(height: 24),
        const Text(
          'What the backup contains',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Administrator signing identity, registered devices and trust bundle version. Imported validation datasets are separate: keep the original phone JSON files so they can be imported again.',
        ),
        const SizedBox(height: 16),
        const Text(
          'Restore requires an empty device registry and a compatible protected identity. It cannot recover a lost browser administrator without its original identity backup. Back up again after publishing trust bundles: an old backup may have a version that existing phones reject.',
        ),
      ],
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.confirm});
  final bool confirm;
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  String? _error;
  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _password.text;
    if (value.length < 12 || value.length > 1024) {
      setState(() => _error = 'Use a password with 12 to 1024 characters.');
    } else if (widget.confirm && value != _repeat.text) {
      setState(() => _error = 'The passwords do not match.');
    } else {
      Navigator.pop(context, value);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.confirm ? 'Protect your backup' : 'Unlock administrator backup',
    ),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _password,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Backup password',
                helperText: 'At least 12 characters',
              ),
            ),
            if (widget.confirm)
              TextField(
                controller: _repeat,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Repeat password'),
              ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _submit,
        child: Text(widget.confirm ? 'Continue' : 'Restore'),
      ),
    ],
  );
}
