import 'package:flutter/material.dart';

import '../../../registration/data/registration_review_api.dart';
import '../../../security/domain/entities/device_registration_qr.dart';
import '../../../trust/domain/entities/trust_bundle.dart';
import '../../data/desktop_admin_registry_repository.dart';
import '../../domain/entities/registered_device.dart';

class RegistrationReviewPanel extends StatefulWidget {
  const RegistrationReviewPanel({
    super.key,
    required this.registry,
    required this.onRegistryChanged,
  });
  final DesktopAdminRegistryRepository registry;
  final VoidCallback onRegistryChanged;

  @override
  State<RegistrationReviewPanel> createState() =>
      _RegistrationReviewPanelState();
}

class _RegistrationReviewPanelState extends State<RegistrationReviewPanel> {
  final _api = RegistrationReviewApi.live();
  final _email = TextEditingController();
  final _password = TextEditingController();
  ({String token, String uid})? _session;
  List<ReviewApplication> _applications = [];
  String _search = '';
  bool _busy = false;
  String _message = '';

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await action();
    } on StateError catch (error) {
      _message = error.message;
    } catch (_) {
      _message =
          'Unable to complete the request. Check the connection and retry.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() => _run(() async {
    final session = await RegistrationReviewApi.signIn(
      _email.text.trim(),
      _password.text,
    );
    if (!mounted) return;
    _password.clear();
    _applications = await _api.list(session.token);
    _session = session;
  });

  Future<void> _decide(ReviewApplication application, String status) async {
    final approving = status == 'approved_pending_publication';
    var role = RegisteredDeviceRole.civilian;
    var reason = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            approving ? 'Approve student and phone' : _status(status),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (approving)
                DropdownButtonFormField<RegisteredDeviceRole>(
                  initialValue: role,
                  decoration: const InputDecoration(labelText: 'Phone role'),
                  items: const [
                    DropdownMenuItem(
                      value: RegisteredDeviceRole.civilian,
                      child: Text('Student'),
                    ),
                    DropdownMenuItem(
                      value: RegisteredDeviceRole.responder,
                      child: Text('Campus responder'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) update(() => role = value);
                  },
                ),
              TextField(
                maxLength: 500,
                decoration: InputDecoration(
                  labelText: status == 'approved_pending_publication'
                      ? 'Reason (optional)'
                      : 'Reason for the applicant',
                ),
                onChanged: (value) => update(() => reason = value.trim()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed:
                  reason.isNotEmpty || status == 'approved_pending_publication'
                  ? () => Navigator.pop(context, true)
                  : null,
              child: Text(approving ? 'Approve and publish' : 'Confirm'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || confirmed != true) return;
    await _run(() async {
      if (approving) {
        try {
          await DeviceRegistrationQr.fromJsonString(
            application.fields['deviceRegistration'] as String,
          ).verifySignature();
        } catch (_) {
          throw StateError('The device registration signature is invalid.');
        }
      }
      final session = _session!;
      await _api.decide(
        session.token,
        session.uid,
        application,
        status,
        reason,
        role: approving ? role.name : null,
      );
      _message = 'Decision recorded.';
      _applications = await _api.list(session.token);
      if (approving) {
        final approved = _applications.singleWhere(
          (item) => item.id == application.id,
        );
        if (approved.status == 'approved_pending_publication') {
          try {
            await _publishApproved(approved);
          } on StateError catch (error) {
            throw StateError(
              'Approval recorded. Publication failed. ${error.message}',
            );
          } catch (_) {
            throw StateError(
              'Approval recorded. Use Publish signed access to retry.',
            );
          }
        }
      }
    });
  }

  String _status(String status) => switch (status) {
    'submitted' => 'Pending review',
    'approved_pending_publication' => 'Approved · awaiting publication',
    'changes_requested' => 'Changes requested',
    'rejected' => 'Rejected',
    'published' => 'Published',
    _ => status,
  };

  String? _phoneId(ReviewApplication application) {
    try {
      return DeviceRegistrationQr.fromJsonString(
        application.fields['deviceRegistration'] as String,
      ).deviceId;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  String? _assignedRole(ReviewApplication application) =>
      application.history.isEmpty
      ? null
      : application.history.last['role'] as String?;

  String _roleLabel(String role) =>
      role == 'responder' ? 'Campus responder' : 'Student';

  Future<void> _publishApproved(ReviewApplication application) async {
    final session = _session!;
    final registration = DeviceRegistrationQr.fromJsonString(
      application.fields['deviceRegistration'] as String,
    );
    await registration.verifySignature();
    final current = await _api.readDirectory(session.token);
    final now = DateTime.now().toUtc();
    final role = _assignedRole(application);
    final source = await widget.registry.stageDirectoryApproval(
      RegisteredDevice(
        deviceId: registration.deviceId,
        ownerName: application.fields['displayName'] as String,
        role: role == 'responder'
            ? RegisteredDeviceRole.responder
            : RegisteredDeviceRole.civilian,
        status: RegisteredDeviceStatus.approved,
        registeredAt: now,
        updatedAt: now,
        lastSeenLabel: 'DNSC registration',
        publicKey: registration.publicKey,
        signingPublicKey: registration.signingPublicKey,
        keyVersion: registration.keyVersion,
      ),
      reviewProject,
      current?.version ?? 0,
      assignRole: role != null,
    );
    if (mounted) widget.onRegistryChanged();
    final bundle = TrustBundle.fromJsonString(source);
    if (current != null &&
        TrustBundle.fromJsonString(current.bundle).issuer?.publicKey !=
            bundle.issuer?.publicKey) {
      throw StateError(
        'Restore the signing identity used for the existing directory.',
      );
    }
    await _api.publish(
      session.token,
      application,
      bundle.bundleVersion,
      source,
    );
    _message = 'Signed access published.';
    _applications = await _api.list(session.token);
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text(
        'Registration requests',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      if (reviewProject.isEmpty || reviewApiKey.isEmpty)
        const Text(
          'This build needs a Firebase project and client API key for online review.',
        )
      else if (_session == null) ...[
        TextField(
          controller: _email,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: 'Reviewer email'),
        ),
        TextField(
          controller: _password,
          enabled: !_busy,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: _busy ? null : _signIn,
            child: const Text('Sign in'),
          ),
        ),
      ] else ...[
        Wrap(
          spacing: 12,
          children: [
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      _applications = await _api.list(_session!.token);
                    }),
              child: const Text('Refresh'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _session = null;
                      _applications = [];
                      _message = '';
                      _search = '';
                    }),
              child: const Text('Sign out'),
            ),
          ],
        ),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Find by name or student number',
          ),
          onChanged: (value) =>
              setState(() => _search = value.trim().toLowerCase()),
        ),
        if (_applications.isEmpty) const Text('No applications yet.'),
        for (final application in _applications.where(
          (item) =>
              '${item.fields['displayName']} ${item.fields['studentNumber']}'
                  .toLowerCase()
                  .contains(_search),
        ))
          Card(
            child: ExpansionTile(
              title: Text('${application.fields['displayName']}'),
              subtitle: Text(_status(application.status)),
              children: [
                if (application.status == 'approved_pending_publication' &&
                    application.id != _session!.uid)
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() => _publishApproved(application)),
                    child: const Text('Publish signed access'),
                  ),
                ListTile(
                  title: Text(
                    '${application.fields['studentNumber']} · ${application.fields['courseYear']}',
                  ),
                  subtitle: Text(
                    [application.fields['phone'], application.fields['address']]
                        .whereType<String>()
                        .where((v) => v.isNotEmpty)
                        .join(' · '),
                  ),
                ),
                ListTile(
                  title: const Text('Submitted phone'),
                  subtitle: SelectableText(
                    _phoneId(application) ?? 'Phone registration is invalid.',
                  ),
                ),
                if (_assignedRole(application) case final role?)
                  ListTile(
                    title: const Text('Assigned role'),
                    subtitle: Text(_roleLabel(role)),
                  ),
                for (final entry in application.history)
                  ListTile(
                    title: Text(_status(entry['status'] as String)),
                    subtitle: Text('${entry['reason']}'),
                  ),
                if (application.status == 'submitted' &&
                    application.id == _session!.uid)
                  const ListTile(
                    title: Text(
                      'Another reviewer must review your application.',
                    ),
                  ),
                if (application.status == 'submitted' &&
                    application.id != _session!.uid)
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _decide(
                                application,
                                'approved_pending_publication',
                              ),
                        child: const Text('Review and approve'),
                      ),
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _decide(application, 'changes_requested'),
                        child: const Text('Request correction'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _decide(application, 'rejected'),
                        child: const Text('Reject'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
      ],
      if (_busy) const LinearProgressIndicator(),
      if (_message.isNotEmpty)
        Semantics(liveRegion: true, child: Text(_message)),
    ],
  );
}
