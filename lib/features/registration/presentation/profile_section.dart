import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../trust/data/services/trust_directory_sync_service.dart';
import '../../trust/domain/entities/device_access_profile.dart';
import '../data/pilot_registration.dart';
import '../data/registration_review_api.dart';
import 'pilot_registration_page.dart';

class ProfileSection extends ConsumerStatefulWidget {
  const ProfileSection({
    super.key,
    required this.access,
    required this.active,
    this.openRegistration,
  });

  final DeviceAccessProfile access;
  final bool active;
  final Future<PilotRegistration> Function()? openRegistration;

  @override
  ConsumerState<ProfileSection> createState() => _ProfileSectionState();
}

class _ProfileSectionState extends ConsumerState<ProfileSection> {
  static const _identityFields = {
    'displayName': 'Full name',
    'studentNumber': 'Student number',
    'courseYear': 'Course and year',
  };
  static const _contactFields = {'phone': 'Phone number', 'address': 'Address'};

  PilotRegistration? _registration;
  User? _user;
  ReviewApplication? _application;
  Map<String, dynamic> _draft = {};
  bool _busy = false;
  bool _reloadAccount = false;
  bool _reviewIsStale = false;
  String _message = '';
  bool get _registrationEnabled =>
      widget.openRegistration != null || pilotRegistrationEnabled;

  @override
  void initState() {
    super.initState();
    if (_registrationEnabled) _loadAccount();
  }

  @override
  void didUpdateWidget(covariant ProfileSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_registrationEnabled && widget.active && !oldWidget.active) {
      _loadAccount();
    }
  }

  Future<void> _loadAccount() async {
    if (_busy) {
      final user = _registration?.auth.currentUser;
      if (_user?.uid != user?.uid) {
        setState(() {
          _user = user;
          _application = null;
          _reviewIsStale = false;
          _draft = {};
        });
      }
      _reloadAccount = true;
      return;
    }
    await _run(_readAccount);
  }

  Future<void> _readAccount() async {
    final registration = _registration ??=
        await (widget.openRegistration ?? PilotRegistration.open)();
    final user = registration.auth.currentUser;
    if (!mounted) return;
    if (_user?.uid != user?.uid) {
      setState(() {
        _user = user;
        _application = null;
        _reviewIsStale = false;
        _draft = {};
      });
    }
    final draft = user == null
        ? <String, dynamic>{}
        : await registration.loadDraft(user.uid);
    if (!mounted || registration.auth.currentUser?.uid != user?.uid) return;
    setState(() => _draft = draft);
    if (user == null) return;
    final cached = await registration.readCachedProfile(user);
    if (!mounted || registration.auth.currentUser?.uid != user.uid) return;
    if (cached != null) {
      setState(() {
        _application = cached;
        _reviewIsStale = true;
      });
    }
    await _refresh();
  }

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
      _message = 'Could not reach DNSC. Check your connection and try again.';
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_reloadAccount) {
          _reloadAccount = false;
          unawaited(_loadAccount());
        }
      }
    }
  }

  Future<void> _refresh({bool syncApproval = false}) async {
    final user = _user;
    if (user == null) return;
    final ReviewApplication? application;
    try {
      application = await _registration!.refreshProfile(user);
    } catch (_) {
      if (mounted && _registration!.auth.currentUser?.uid == user.uid) {
        setState(() => _reviewIsStale = _application != null);
      }
      rethrow;
    }
    if (!mounted || _registration!.auth.currentUser?.uid != user.uid) return;
    setState(() {
      _application = application;
      _reviewIsStale = false;
    });
    if (syncApproval && application?.status == 'published') {
      final binding = application?.fields['deviceRegistration'];
      if (binding is String &&
          await ref.read(registrationMatchesPhoneProvider(binding).future) &&
          mounted &&
          _registration!.auth.currentUser?.uid == user.uid) {
        await ref.read(trustDirectorySyncProvider).refresh();
      }
    }
  }

  Future<void> _openRegistration() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PilotRegistrationPage(
          openRegistration: widget.openRegistration ?? PilotRegistration.open,
        ),
      ),
    );
    if (!mounted) return;
    await _loadAccount();
  }

  Future<void> _edit({required bool identity}) async {
    final application = _application;
    final user = _user;
    if (application == null || user == null) return;
    final labels = identity ? _identityFields : _contactFields;
    final initial = labels.map(
      (key, _) => MapEntry(key, application.fields[key] as String? ?? ''),
    );
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProfileEditDialog(
        identity: identity,
        labels: labels,
        initial: initial,
        onSave: (values) async {
          final registration = _registration!;
          if (registration.auth.currentUser?.uid != user.uid) {
            throw StateError('Sign in again before saving.');
          }
          final changes = identity
              ? {
                  'profileChange': {...values, 'status': 'submitted'},
                }
              : values;
          try {
            await registration.updateProfile(user, application, changes);
          } catch (_) {
            // A response can be lost after the server accepts the write.
            final latest = await registration.refreshProfile(user);
            if (latest != null) {
              final actual = identity ? latest.profileChange : latest.fields;
              final matches = values.entries.every(
                (entry) => actual?[entry.key] == entry.value,
              );
              if (matches &&
                  (!identity ||
                      actual?['status'] == 'submitted' ||
                      actual?['status'] == 'approved_pending_publication')) {
                return;
              }
            }
            rethrow;
          }
        },
      ),
    );
    if (!mounted ||
        saved != true ||
        _registration!.auth.currentUser?.uid != user.uid) {
      return;
    }
    await _run(() async {
      _message = identity
          ? 'Change sent for review.'
          : 'Contact details saved.';
      try {
        await _refresh();
      } catch (_) {
        _message += ' Check again online for the latest profile.';
      }
    });
  }

  String _registrationStatus(String? status, bool? matchesPhone) {
    return switch (status) {
      'changes_requested' => 'Changes requested',
      'approved_pending_publication' =>
        'Approved · waiting for campus activation',
      'published' when matchesPhone == false =>
        'Account approved · phone approval needed',
      'published' when matchesPhone == true && widget.access.isApproved =>
        'Active on this phone',
      'published' => 'Approved · phone activation needed',
      'rejected' => 'Application declined',
      'submitted' => 'Pending review',
      _ =>
        _draft['submitted'] == true
            ? 'Review status unavailable'
            : _user == null
            ? 'Signed out'
            : 'Registration incomplete',
    };
  }

  @override
  Widget build(BuildContext context) {
    final access = widget.access;
    final fields = _application?.fields ?? _draft;
    final changeStatus = _application?.profileChange?['status'];
    final awaitingChange =
        changeStatus == 'submitted' ||
        changeStatus == 'approved_pending_publication';
    final canEdit = _application?.status == 'published' && _user != null;
    final status = _application?.status;
    final binding = _application?.fields['deviceRegistration'];
    final matchesPhone = status == 'published' && binding is String
        ? ref.watch(registrationMatchesPhoneProvider(binding)).asData?.value
        : null;
    final detailLabels = {..._identityFields, ..._contactFields};
    final details = {
      for (final entry in detailLabels.entries)
        if (fields[entry.key] case final String value when value.isNotEmpty)
          entry.value: value,
      if (_user?.email case final String email) 'Email': email,
    };
    final title = fields['displayName'] as String?;
    final phoneStatus = switch (access.level) {
      DeviceAccessLevel.revoked => 'Approval removed',
      DeviceAccessLevel.keyMismatch => 'This phone needs approval again',
      DeviceAccessLevel.outdatedBundle => 'Phone approval expired',
      DeviceAccessLevel.unregistered => 'Phone approval needed',
      _ => '${access.roleLabel} · Active on this phone',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.phone_android),
          title: const Text('This phone’s offline access'),
          subtitle: Text(
            access.isApproved
                ? phoneStatus
                : '$phoneStatus\nYou can still send an SOS. Contact campus staff if you need phone approval.',
          ),
        ),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.account_circle_outlined, size: 32),
                title: Text(title ?? 'Your account'),
                subtitle: Text(
                  _reviewIsStale
                      ? 'Last known · ${_registrationStatus(status, matchesPhone)}'
                      : _registrationStatus(status, matchesPhone),
                ),
              ),
              if (status == 'approved_pending_publication')
                const ListTile(
                  subtitle: Text(
                    'Campus staff still need to release phone access. Check again when online.',
                  ),
                )
              else if (status == 'submitted')
                const ListTile(
                  subtitle: Text(
                    'Campus staff are reviewing your application.',
                  ),
                )
              else if (matchesPhone == false || status == 'rejected')
                ListTile(
                  subtitle: Text(
                    matchesPhone == false
                      ? 'Clearing app data or changing phones can require a new approval. Contact campus staff to approve this installation.'
                        : 'Contact campus staff about your application.',
                  ),
                ),
              if (status == 'changes_requested' &&
                  _application!.history.isNotEmpty)
                ListTile(
                  title: Text(
                    _application!.history.last['reason'] as String? ?? '',
                  ),
                ),
              if (_registrationEnabled && _user == null)
                ListTile(
                  leading: const Icon(Icons.login),
                  title: const Text('Sign in or register with DNSC'),
                  onTap: _busy ? null : _openRegistration,
                )
              else if (status == 'published' &&
                  matchesPhone == true &&
                  !access.isApproved)
                ListTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('Activate this phone'),
                  onTap: _busy
                      ? null
                      : () => _run(() => _refresh(syncApproval: true)),
                )
              else if (status == 'changes_requested')
                ListTile(
                  leading: const Icon(Icons.edit_note_outlined),
                  title: const Text('Update application'),
                  onTap: _busy ? null : _openRegistration,
                )
              else if (_user != null &&
                  status == null &&
                  _draft['submitted'] != true)
                ListTile(
                  leading: const Icon(Icons.edit_note_outlined),
                  title: const Text('Finish registration'),
                  onTap: _busy ? null : _openRegistration,
                )
              else if (_user != null &&
                  matchesPhone != false &&
                  status != 'rejected')
                ListTile(
                  leading: const Icon(Icons.refresh),
                  title: const Text('Check status'),
                  onTap: _busy
                      ? null
                      : () => _run(() => _refresh(syncApproval: true)),
                ),
              if (_busy) const LinearProgressIndicator(),
              if (_message.isNotEmpty)
                ListTile(
                  title: Semantics(liveRegion: true, child: Text(_message)),
                ),
            ],
          ),
        ),
        if (details.isNotEmpty || canEdit)
          Card(
            child: ExpansionTile(
              title: const Text('Personal details'),
              leading: const Icon(Icons.badge_outlined),
              children: [
                for (final entry in details.entries)
                  ListTile(title: Text(entry.key), subtitle: Text(entry.value)),
                if (canEdit) ...[
                  ListTile(
                    title: const Text('Edit phone and address'),
                    onTap: _busy ? null : () => _edit(identity: false),
                  ),
                  ListTile(
                    title: const Text('Request an identity change'),
                    subtitle: Text(
                      awaitingChange
                          ? 'Your request is awaiting review or publication.'
                          : changeStatus == 'rejected'
                          ? 'Your last request was declined.'
                          : 'Changes to name, student number, or course need admin approval.',
                    ),
                    onTap: _busy || awaitingChange
                        ? null
                        : () => _edit(identity: true),
                  ),
                ],
              ],
            ),
          ),
        if (_user != null)
          ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const Text('DNSC account settings'),
            subtitle: const Text('View registration or sign out.'),
            onTap: _busy ? null : _openRegistration,
          ),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: const Text('Settings'),
          onTap: () async {
            await Navigator.of(context).pushNamed('/settings');
            if (mounted && _registrationEnabled) {
              await _loadAccount();
            }
          },
        ),
      ],
    );
  }
}

class _ProfileEditDialog extends StatefulWidget {
  const _ProfileEditDialog({
    required this.identity,
    required this.labels,
    required this.initial,
    required this.onSave,
  });

  final bool identity;
  final Map<String, String> labels;
  final Map<String, String> initial;
  final Future<void> Function(Map<String, String>) onSave;

  @override
  State<_ProfileEditDialog> createState() => _ProfileEditDialogState();
}

class _ProfileEditDialogState extends State<_ProfileEditDialog> {
  final _form = GlobalKey<FormState>();
  late final _values = Map<String, String>.of(widget.initial);
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(Map.of(_values));
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error =
            'Could not save your changes. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: Text(
        widget.identity ? 'Request an identity change' : 'Edit contact details',
      ),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in widget.labels.entries)
              TextFormField(
                enabled: !_saving,
                initialValue: _values[entry.key],
                maxLength: entry.key == 'address' ? 200 : 100,
                keyboardType: entry.key == 'phone' ? TextInputType.phone : null,
                decoration: InputDecoration(labelText: entry.value),
                onChanged: (value) =>
                    setState(() => _values[entry.key] = value.trim()),
                validator: (value) =>
                    widget.identity && (value ?? '').trim().isEmpty
                    ? 'Enter ${entry.value.toLowerCase()}.'
                    : null,
              ),
            if (_error case final error?)
              Semantics(liveRegion: true, child: Text(error)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              _saving ||
                  _values.entries.every(
                    (entry) => widget.initial[entry.key] == entry.value,
                  )
              ? null
              : _save,
          child: Text(
            _saving
                ? 'Saving…'
                : widget.identity
                ? 'Send for review'
                : 'Save',
          ),
        ),
      ],
    ),
  );
}
