import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../messaging/presentation/providers/local_messaging_providers.dart';
import '../../security/domain/entities/device_registration_qr.dart';
import '../data/pilot_registration.dart';
import '../data/registration_review_api.dart';
import '../../trust/data/services/trust_directory_sync_service.dart';
import '../../trust/presentation/providers/device_access_provider.dart';

final registrationMatchesPhoneProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, binding) async {
      final DeviceRegistrationQr registration;
      try {
        registration = DeviceRegistrationQr.fromJsonString(binding);
      } on FormatException {
        return false;
      }
      final peer = ref.watch(localPeerProvider.future);
      final crypto = ref.watch(deviceCryptoIdentityProvider.future);
      final signing = ref.watch(deviceSigningIdentityProvider.future);
      final identity = await crypto;
      return registration.deviceId == (await peer).id &&
          registration.publicKey == identity.encodedPublicKey &&
          registration.keyVersion == identity.keyVersion &&
          registration.signingPublicKey == (await signing).encodedPublicKey;
    });

class PilotRegistrationEntry extends StatelessWidget {
  const PilotRegistrationEntry({super.key});

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.school_outlined),
    title: Text(
      pilotRegistrationIsLive ? 'DNSC registration' : 'DNSC test registration',
    ),
    onTap: () => Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const PilotRegistrationPage()),
    ),
  );
}

class PilotRegistrationPage extends ConsumerStatefulWidget {
  const PilotRegistrationPage({
    super.key,
    this.onContinue,
    this.openCorrection = false,
  });

  final VoidCallback? onContinue;
  final bool openCorrection;

  @override
  ConsumerState<PilotRegistrationPage> createState() =>
      _PilotRegistrationState();
}

class _PilotRegistrationState extends ConsumerState<PilotRegistrationPage> {
  static const _labels = {
    'displayName': 'Full name',
    'studentNumber': 'Student number',
    'courseYear': 'Course and year',
    'phone': 'Phone number (optional)',
    'address': 'Address (optional)',
  };
  final _fields = {
    for (final key in _labels.keys) key: TextEditingController(),
  };
  final _email = TextEditingController();
  final _password = TextEditingController();
  PilotRegistration? _repository;
  User? _user;
  bool _busy = true;
  bool _submitting = false;
  bool _locked = false;
  bool _submitted = false;
  String? _device;
  ReviewApplication? _correction;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      _repository = await PilotRegistration.open();
      await _loadUser();
      if (mounted && widget.openCorrection && _user != null) {
        await _readStatus();
      }
    } catch (_) {
      _message = pilotRegistrationIsLive
          ? 'Registration is unavailable. You can try again when online.'
          : 'Unable to load registration. Check the local Firebase emulator.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadUser() async {
    final user = _repository!.auth.currentUser;
    final draft = user == null
        ? <String, dynamic>{}
        : await _repository!.loadDraft(user.uid);
    if (!mounted) return;
    _user = user;
    _correction = null;
    for (final entry in _fields.entries) {
      entry.value.text = draft[entry.key] as String? ?? '';
    }
    _device = draft['deviceRegistration'] as String?;
    _locked = _device != null;
    _submitted = draft['submitted'] == true;
    _message = _submitted
        ? 'Submitted. Pending review.'
        : _locked
        ? 'Submission incomplete. Retry to resume.'
        : draft.isEmpty
        ? ''
        : 'Saved draft restored.';
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool submitting = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _submitting = submitting;
    });
    try {
      await action();
    } on FirebaseAuthException catch (error) {
      _message = error.message ?? 'Sign-in failed.';
    } on StateError catch (error) {
      _message = error.message;
    } catch (_) {
      _message = pilotRegistrationIsLive
          ? 'Unable to finish. Check your internet connection and try again.'
          : 'Unable to finish. Check the emulator connection and retry.';
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _submitting = false;
        });
      }
    }
  }

  Future<void> _authenticate({required bool create}) => _run(() async {
    final auth = _repository!.auth;
    final email = _email.text.trim();
    final password = _password.text;
    if (create) {
      await auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
    } else {
      await auth.signInWithEmailAndPassword(email: email, password: password);
    }
    if (!mounted) return;
    _password.clear();
    await _loadUser();
  });

  Map<String, String> get _details => {
    for (final entry in _fields.entries) entry.key: entry.value.text.trim(),
  };

  Future<void> _refreshStatus() => _run(_readStatus);

  Future<void> _readStatus() async {
    final application = await _repository!.readStatus(_user!);
    if (!mounted) return;
    if (application == null) {
      _message = 'No submitted application found.';
      return;
    }
    final history = application.history;
    final reason = history.isEmpty ? '' : history.last['reason'] as String;
    if (application.status == 'changes_requested') {
      if (_correction?.updateTime != application.updateTime) {
        for (final field in _fields.entries) {
          field.value.text = application.fields[field.key] as String? ?? '';
        }
      }
      _device = application.fields['deviceRegistration'] as String;
      _correction = application;
      _locked = false;
      _submitted = false;
      _message = 'Changes requested. $reason';
      return;
    }
    _correction = null;
    _submitted = true;
    if (application.status == 'published') {
      final binding = application.fields['deviceRegistration'];
      final matches =
          binding is String &&
          await ref.read(registrationMatchesPhoneProvider(binding).future);
      if (!mounted) return;
      if (!matches) {
        _message = 'This account was approved for a different phone.';
        return;
      }
      _message = 'Access published. Syncing approval…';
      await ref.read(trustDirectorySyncProvider).refresh();
      if (!mounted) return;
      final access = await ref.read(deviceAccessProfileProvider.future);
      _message = access.isApproved
          ? 'Access active on this phone.\n${access.roleLabel}'
          : 'Access was published. Check the registered phone and signing key.';
      return;
    }
    _message = switch (application.status) {
      'approved_pending_publication' =>
        'Approved. Waiting for access to be published.',
      'rejected' => 'Application rejected. $reason',
      _ => 'Submitted. Pending review.',
    };
  }

  Future<void> _save() => _repository!.saveDraft(_user!.uid, {
    ..._details,
    'deviceRegistration': _device,
    'submitted': _submitted,
  });

  Future<void> _submit() => _run(() async {
    final details = _details;
    if ([
      'displayName',
      'studentNumber',
      'courseYear',
    ].any((key) => details[key]!.isEmpty)) {
      throw StateError('Fill in the required details.');
    }
    final peer = ref.read(localPeerProvider.future);
    final crypto = ref.read(deviceCryptoIdentityProvider.future);
    final signing = ref.read(deviceSigningIdentityProvider.future);
    final registration = await DeviceRegistrationQr.createSigned(
      deviceId: (await peer).id,
      identity: await crypto,
      signingIdentity: await signing,
    );
    if (!mounted) return;
    final binding = jsonEncode(registration.toJson());
    if (_device != null && _device != binding) {
      throw StateError('This draft belongs to different device keys.');
    }
    _device = binding;
    _locked = true;
    await _save();
    if (!mounted) return;
    setState(() => _message = 'Submitting application…');
    final user = _user!;
    final correction = _correction;
    if (correction == null) {
      await _repository!.submit(user, {
        ...details,
        'status': 'submitted',
        'deviceRegistration': binding,
      });
    } else {
      await _repository!.resubmit(user, correction, details);
      _correction = null;
    }
    _submitted = true;
    await _repository!.saveDraft(user.uid, {
      ...details,
      'deviceRegistration': binding,
      'submitted': true,
    });
    _message = 'Submitted. Pending review.';
  }, submitting: true);

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      PopScope(canPop: !_submitting, child: _buildPage());

  Widget _buildPage() => Scaffold(
    appBar: AppBar(
      title: Text(
        pilotRegistrationIsLive
            ? 'DNSC registration'
            : 'DNSC test registration',
      ),
    ),
    bottomNavigationBar: widget.onContinue == null
        ? null
        : SafeArea(
            minimum: const EdgeInsets.all(16),
            child: OutlinedButton(
              onPressed: _submitting ? null : widget.onContinue,
              child: Text(
                _user == null ? 'Continue unverified' : 'Continue to Home',
              ),
            ),
          ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.onContinue != null)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text(
              'Sign in or create an account to request DNSC access. '
              'You can use the app and send an SOS while waiting for approval.',
            ),
          ),
        if (!pilotRegistrationIsLive)
          const Text('Use synthetic details for this local test.'),
        if (_busy) const LinearProgressIndicator(),
        if (_message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Semantics(liveRegion: true, child: Text(_message)),
          ),
        if (_repository != null && _user == null) ...[
          TextField(
            controller: _email,
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          TextField(
            controller: _password,
            enabled: !_busy,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          FilledButton(
            onPressed: _busy ? null : () => _authenticate(create: true),
            child: const Text('Create account'),
          ),
          TextButton(
            onPressed: _busy ? null : () => _authenticate(create: false),
            child: const Text('Sign in'),
          ),
        ],
        if (_user != null) ...[
          TextButton(
            onPressed: _busy ? null : _refreshStatus,
            child: const Text('Check review status'),
          ),
          if (!_submitted) ...[
            for (final entry in _labels.entries)
              TextField(
                controller: _fields[entry.key],
                enabled: !_busy && !_locked,
                maxLength: entry.key == 'address' ? 200 : 100,
                decoration: InputDecoration(labelText: entry.value),
              ),
            if (!_locked)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await _save();
                        _message = 'Draft saved on this phone.';
                      }),
                child: const Text('Save draft'),
              ),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(_locked ? 'Retry submission' : 'Submit for review'),
            ),
          ],
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _repository!.auth.signOut();
                    await _loadUser();
                  }),
            child: const Text('Sign out'),
          ),
        ],
      ],
    ),
  );
}
