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

class PilotRegistrationPage extends ConsumerStatefulWidget {
  const PilotRegistrationPage({
    super.key,
    this.onContinue,
    this.openRegistration = PilotRegistration.open,
  });

  final VoidCallback? onContinue;
  final Future<PilotRegistration> Function() openRegistration;

  @override
  ConsumerState<PilotRegistrationPage> createState() =>
      _PilotRegistrationState();
}

class _PilotRegistrationState extends ConsumerState<PilotRegistrationPage> {
  static const _requiredDetailLabels = {
    'displayName': 'Full name',
    'studentNumber': 'Student number',
    'courseYear': 'Course and year',
  };
  static const _labels = {
    ..._requiredDetailLabels,
    'phone': 'Phone number (optional)',
    'address': 'Address (optional)',
  };
  final _fields = {
    for (final key in _labels.keys) key: TextEditingController(),
  };
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _requiredFocusNodes = {
    'email': FocusNode(),
    'password': FocusNode(),
    for (final key in _requiredDetailLabels.keys) key: FocusNode(),
  };
  Set<String> _missingFields = {};
  PilotRegistration? _repository;
  User? _user;
  bool _busy = true;
  bool _navigationLocked = false;
  bool _locked = false;
  bool _submitted = false;
  String? _device;
  String? _draftCorrectionRevision;
  ReviewApplication? _application;
  ReviewApplication? _correction;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      _repository = await widget.openRegistration();
      await _loadUser();
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
    if (!mounted || _repository!.auth.currentUser?.uid != user?.uid) return;
    _user = user;
    _application = null;
    _correction = null;
    _missingFields.clear();
    for (final entry in _fields.entries) {
      entry.value.text = draft[entry.key] as String? ?? '';
    }
    _device = draft['deviceRegistration'] as String?;
    _draftCorrectionRevision = draft['correctionRevision'] as String?;
    _locked = _device != null;
    _submitted = draft['submitted'] == true;
    _message = _submitted
        ? 'Checking review status…'
        : _locked
        ? 'Submission incomplete. Retry to resume.'
        : draft.isEmpty
        ? ''
        : 'Saved draft restored.';
    if (user == null) return;
    setState(() {});
    ReviewApplication? cached;
    try {
      cached = await _repository!.readCachedProfile(user);
    } catch (_) {
      // A damaged cache can be replaced by the next online refresh.
    }
    if (!_isCurrentUser(user)) return;
    if (cached != null &&
        !(cached.status == 'changes_requested' &&
            _submitted &&
            cached.updateTime == _draftCorrectionRevision)) {
      await _applyStatus(cached, syncApproval: false);
      if (!_isCurrentUser(user)) return;
      setState(() {});
    }
    await _readStatus(showMissingApplication: _submitted || cached != null);
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool lockNavigation = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _navigationLocked = lockNavigation;
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
          _navigationLocked = false;
        });
      }
    }
  }

  Future<void> _authenticate({required bool create}) async {
    final email = _email.text.trim();
    final password = _password.text;
    if (_busy ||
        !_validateRequiredFields({'email': email, 'password': password})) {
      return;
    }
    await _run(() async {
      final auth = _repository!.auth;
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
    }, lockNavigation: true);
  }

  Map<String, String> get _details => {
    for (final entry in _fields.entries) entry.key: entry.value.text.trim(),
  };

  Future<void> _refreshStatus() => _run(_readStatus);

  bool _isCurrentUser(User user) =>
      mounted && _repository!.auth.currentUser?.uid == user.uid;

  Future<void> _readStatus({bool showMissingApplication = true}) async {
    final user = _user;
    if (user == null) return;
    final ReviewApplication? application;
    try {
      application = await _repository!.refreshProfile(user);
    } catch (_) {
      if (_isCurrentUser(user) && _application == null) {
        _message = 'Review status unavailable. Try again when online.';
      }
      return;
    }
    if (!_isCurrentUser(user)) return;
    if (application == null) {
      _application = null;
      _correction = null;
      _submitted = false;
      _locked = _device != null;
      if (showMissingApplication) _message = 'No submitted application found.';
      return;
    }
    await _applyStatus(application, syncApproval: true);
  }

  Future<void> _applyStatus(
    ReviewApplication application, {
    required bool syncApproval,
  }) async {
    final user = _user!;
    _application = application;
    final history = application.history;
    final reason = history.isEmpty ? '' : history.last['reason'] as String;
    if (application.status == 'changes_requested') {
      if ((_correction?.updateTime ?? _draftCorrectionRevision) !=
          application.updateTime) {
        _missingFields.clear();
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
      _message = 'Access published. Checking this phone…';
      final binding = application.fields['deviceRegistration'];
      final matches =
          binding is String &&
          await ref.read(registrationMatchesPhoneProvider(binding).future);
      if (!_isCurrentUser(user)) return;
      if (!matches) {
        _message = 'This account was approved for a different phone.';
        return;
      }
      var access = await ref.read(deviceAccessProfileProvider.future);
      if (!_isCurrentUser(user)) return;
      if (syncApproval && !access.isApproved) {
        try {
          await ref.read(trustDirectorySyncProvider).refresh();
          if (!_isCurrentUser(user)) return;
          access = await ref.read(deviceAccessProfileProvider.future);
        } catch (_) {
          if (_isCurrentUser(user)) {
            _message = 'Access was published. Sync approval when online.';
          }
          return;
        }
      }
      if (!_isCurrentUser(user)) return;
      _message = access.isApproved
          ? 'Access active on this phone.\n${access.roleLabel}'
          : 'Access was published. Check the registered phone and signing key.';
      return;
    }
    _message = switch (application.status) {
      'approved_pending_publication' =>
        'Approved. Waiting for access to be published.',
      'rejected' => 'Application rejected. $reason',
      'submitted' => 'Submitted. Pending review.',
      _ => 'Review status unavailable.',
    };
  }

  Future<void> _save() => _repository!.saveDraft(_user!.uid, {
    ..._details,
    'deviceRegistration': _device,
    'submitted': _submitted,
    'correctionRevision': _correction?.updateTime,
  });

  bool _validateRequiredFields(Map<String, String> values) {
    final missing = {
      for (final entry in values.entries)
        if (entry.value.isEmpty) entry.key,
    };
    setState(() => _missingFields = missing);
    if (missing.isEmpty) return true;

    final focusNode = _requiredFocusNodes[missing.first]!;
    focusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final fieldContext = focusNode.context;
      if (fieldContext != null) {
        Scrollable.ensureVisible(fieldContext, alignment: 0.1);
      }
    });
    return false;
  }

  void _clearFieldError(String key, String value) {
    if (value.isNotEmpty && _missingFields.contains(key)) {
      setState(() => _missingFields.remove(key));
    }
  }

  InputDecoration _requiredDecoration(String key, String label) =>
      InputDecoration(
        labelText: '$label (required)',
        errorText: _missingFields.contains(key)
            ? 'Enter your ${label.toLowerCase()}.'
            : null,
        errorMaxLines: 2,
      );

  Future<void> _submit() async {
    if (_busy) return;
    final details = _details;
    if (_validateRequiredFields({
      for (final key in _requiredDetailLabels.keys) key: details[key]!,
    })) {
      await _submitDetails(details);
    }
  }

  Future<void> _submitDetails(Map<String, String> details) => _run(() async {
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
      _application = null;
    }
    _submitted = true;
    await _repository!.saveDraft(user.uid, {
      ...details,
      'deviceRegistration': binding,
      'submitted': true,
      'correctionRevision': correction?.updateTime,
    });
    _message = 'Submitted. Pending review.';
  }, lockNavigation: true);

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    for (final controller in _fields.values) {
      controller.dispose();
    }
    for (final node in _requiredFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      PopScope(canPop: !_navigationLocked, child: _buildPage());

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
              onPressed: _navigationLocked ? null : widget.onContinue,
              child: Text(
                _user == null
                    ? 'Continue without an account'
                    : 'Continue to Home',
                textAlign: TextAlign.center,
              ),
            ),
          ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.onContinue != null)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'Sign in or create an account to request DNSC access. '
                'You can send an SOS right away, even without an account. '
                'To register later or check your status, open Profile.',
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
              focusNode: _requiredFocusNodes['email'],
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              onChanged: (value) => _clearFieldError('email', value.trim()),
              decoration: _requiredDecoration('email', 'Email'),
            ),
            TextField(
              controller: _password,
              focusNode: _requiredFocusNodes['password'],
              enabled: !_busy,
              obscureText: true,
              onChanged: (value) => _clearFieldError('password', value),
              decoration: _requiredDecoration('password', 'Password'),
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
                  focusNode: _requiredFocusNodes[entry.key],
                  enabled: !_busy && !_locked,
                  maxLength: entry.key == 'address' ? 200 : 100,
                  onChanged: (value) =>
                      _clearFieldError(entry.key, value.trim()),
                  decoration: _requiredDetailLabels.containsKey(entry.key)
                      ? _requiredDecoration(entry.key, entry.value)
                      : InputDecoration(labelText: entry.value),
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
    ),
  );
}
