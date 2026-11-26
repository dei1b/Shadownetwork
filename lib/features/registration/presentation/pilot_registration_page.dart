import 'dart:convert';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/mobile_ui_tokens.dart';
import '../../../core/widgets/mobile_ui_components.dart';
import '../../messaging/presentation/providers/local_messaging_providers.dart';
import '../../security/domain/entities/device_registration_qr.dart';
import '../../trust/data/services/trust_directory_sync_service.dart';
import '../../trust/domain/entities/approval_receipt.dart';
import '../../trust/presentation/providers/device_access_provider.dart';
import '../data/pilot_registration.dart';
import '../data/registration_review_api.dart';
import '../domain/campus_identity_fields.dart';

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
    this.initiallyCreatingAccount = false,
    this.openRegistration = PilotRegistration.open,
  });

  final VoidCallback? onContinue;
  final bool initiallyCreatingAccount;
  final Future<PilotRegistration> Function() openRegistration;

  @override
  ConsumerState<PilotRegistrationPage> createState() =>
      _PilotRegistrationState();
}

class _PilotRegistrationState extends ConsumerState<PilotRegistrationPage> {
  static const _studentRequiredLabels = {
    'displayName': 'Full name',
    'studentNumber': 'Student number',
    'course': 'Course',
    'yearLevel': 'Year',
    'sectionSet': 'Set',
  };
  static const _staffRequiredLabels = {
    'displayName': 'Full name',
    'employeeId': 'Employee ID',
    'unit': 'Unit or office',
  };
  static const _optionalDetailLabels = {
    'phone': 'Phone number (optional)',
    'address': 'Address (optional)',
  };
  static const _allFieldKeys = [
    'displayName',
    'studentNumber',
    'course',
    'yearLevel',
    'sectionSet',
    'employeeId',
    'unit',
    'phone',
    'address',
  ];
  static const _fieldIcons = {
    'displayName': Icons.person_outline_rounded,
    'studentNumber': Icons.badge_outlined,
    'course': Icons.school_outlined,
    'yearLevel': Icons.calendar_today_outlined,
    'sectionSet': Icons.group_outlined,
    'employeeId': Icons.work_outline_rounded,
    'unit': Icons.apartment_outlined,
    'phone': Icons.phone_outlined,
    'address': Icons.home_outlined,
  };
  final _fields = {
    for (final key in _allFieldKeys) key: TextEditingController(),
  };
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _recoverySchoolId = TextEditingController();
  final _recoveryName = TextEditingController();
  final _requiredFocusNodes = {
    'email': FocusNode(),
    'password': FocusNode(),
    for (final key in {..._studentRequiredLabels.keys, ..._staffRequiredLabels.keys})
      key: FocusNode(),
  };
  CampusAffiliation _affiliation = CampusAffiliation.student;
  bool _hasLegacyCourseYearOnly = false;
  bool _showRecoveryForm = false;
  SignedApprovalReceipt? _localReceipt;
  ReviewApplication? _linkRequest;
  ReviewApplication? _recoveryRequest;
  Set<String> _missingFields = {};

  Map<String, String> get _activeRequiredLabels =>
      _affiliation == CampusAffiliation.staff
      ? _staffRequiredLabels
      : _studentRequiredLabels;
  PilotRegistration? _repository;
  User? _user;
  bool _busy = true;
  bool _restoreFailed = false;
  late bool _createAccount = widget.initiallyCreatingAccount;
  bool _showPassword = false;
  bool _navigationLocked = false;
  bool _reviewIsStale = false;
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
      if (!mounted) return;
      await _loadUser();
    } catch (_) {
      _restoreFailed = true;
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
    _reviewIsStale = false;
    _correction = null;
    _linkRequest = null;
    _recoveryRequest = null;
    _showRecoveryForm = false;
    _missingFields.clear();
    final draftIdentity = CampusIdentityFields.fromFirestoreFields(draft);
    _affiliation = draftIdentity.affiliation;
    _fields['displayName']!.text = draftIdentity.displayName;
    _fields['studentNumber']!.text = draftIdentity.studentNumber;
    _fields['course']!.text = draftIdentity.course;
    _fields['yearLevel']!.text = draftIdentity.yearLevel;
    _fields['sectionSet']!.text = draftIdentity.sectionSet;
    _fields['employeeId']!.text = draftIdentity.employeeId;
    _fields['unit']!.text = draftIdentity.unit;
    _fields['phone']!.text = draftIdentity.phone;
    _fields['address']!.text = draftIdentity.address;
    _hasLegacyCourseYearOnly =
        (draft['course'] as String? ?? '').isEmpty &&
        (draft['yearLevel'] as String? ?? '').isEmpty &&
        (draft['sectionSet'] as String? ?? '').isEmpty &&
        (draft['courseYear'] as String? ?? '').isNotEmpty;
    _localReceipt = null;
    if (user != null) {
      try {
        final loadedReceipt = await ref
            .read(trustBundleStoreProvider)
            .loadReceipt();
        if (loadedReceipt != null) {
          final peer = await ref.read(localPeerProvider.future);
          final crypto = await ref.read(deviceCryptoIdentityProvider.future);
          final signing = await ref.read(deviceSigningIdentityProvider.future);
          _localReceipt =
              loadedReceipt.matchesPhone(
                deviceId: peer.id,
                publicKey: crypto.encodedPublicKey,
                signingPublicKey: signing.encodedPublicKey,
                keyVersion: crypto.keyVersion,
              )
              ? loadedReceipt
              : null;
        }
      } catch (_) {
        _localReceipt = null;
      }
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
      _message = switch (error.code) {
        'invalid-email' => 'Enter a valid email address.',
        'invalid-credential' || 'wrong-password' || 'user-not-found' =>
          'Check your email and password, or reset your password.',
        'email-already-in-use' =>
          'This email already has an account. Sign in instead.',
        'weak-password' => 'Choose a stronger password.',
        'network-request-failed' =>
          'Check your internet connection and try again.',
        'too-many-requests' =>
          'Too many attempts. Wait a moment and try again.',
        _ => 'Could not complete the account request. Try again.',
      };
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
      TextInput.finishAutofillContext();
      _password.clear();
      await _loadUser();
    }, lockNavigation: true);
  }

  Future<void> _resetPassword() async {
    final email = _email.text.trim();
    if (_busy || !_validateRequiredFields({'email': email})) return;
    await _run(() async {
      try {
        await _repository!.auth.sendPasswordResetEmail(email: email);
      } on FirebaseAuthException catch (error) {
        if (error.code != 'user-not-found') rethrow;
      }
      _message =
          'If an account exists for this email, a password reset link will be sent.';
    });
  }

  Map<String, String> get _details {
    final identity = CampusIdentityFields(
      affiliation: _affiliation,
      displayName: _fields['displayName']!.text.trim(),
      studentNumber: _fields['studentNumber']!.text.trim(),
      course: _fields['course']!.text.trim(),
      yearLevel: _fields['yearLevel']!.text.trim(),
      sectionSet: _fields['sectionSet']!.text.trim(),
      employeeId: _fields['employeeId']!.text.trim(),
      unit: _fields['unit']!.text.trim(),
      phone: _fields['phone']!.text.trim(),
      address: _fields['address']!.text.trim(),
    );
    return identity.toFirestoreFields();
  }

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
      if (_isCurrentUser(user)) {
        _reviewIsStale = _application != null;
        if (!_reviewIsStale) {
          _message = 'Review status unavailable. Try again when online.';
        }
      }
      return;
    }
    if (!_isCurrentUser(user)) return;
    _reviewIsStale = false;
    if (application == null) {
      _application = null;
      _correction = null;
      _submitted = false;
      _locked = _device != null;
      try {
        if (_localReceipt != null) {
          _linkRequest = await _repository!.readLinkRequest(user);
        }
        _recoveryRequest = await _repository!.readRecoveryRequest(user);
      } catch (_) {}
      if (showMissingApplication &&
          _linkRequest == null &&
          _recoveryRequest == null) {
        _message = 'No submitted application found.';
      }
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
        final identity = CampusIdentityFields.fromFirestoreFields(
          application.fields,
        );
        _affiliation = identity.affiliation;
        _fields['displayName']!.text = identity.displayName;
        _fields['studentNumber']!.text = identity.studentNumber;
        _fields['course']!.text = identity.course;
        _fields['yearLevel']!.text = identity.yearLevel;
        _fields['sectionSet']!.text = identity.sectionSet;
        _fields['employeeId']!.text = identity.employeeId;
        _fields['unit']!.text = identity.unit;
        _fields['phone']!.text = identity.phone;
        _fields['address']!.text = identity.address;
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
        _message =
            'Your account is approved, but this phone needs approval again. '
            'This can happen after clearing app data or changing phones. '
            'Contact the campus administrator to approve this installation.';
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

  void _setCreateAccount(bool create) {
    if (_busy || _createAccount == create) return;
    setState(() {
      _createAccount = create;
      _showPassword = false;
      _missingFields.clear();
      _message = '';
      _password.clear();
    });
  }

  InputDecoration _requiredDecoration(
    String key,
    String label, {
    IconData? icon,
    Widget? suffixIcon,
  }) => MobileInputStyles.decoration(
    labelText: '$label (required)',
    errorText: _missingFields.contains(key)
        ? 'Enter your ${label.toLowerCase()}.'
        : null,
    prefixIcon: icon == null
        ? null
        : Icon(icon, size: 20, color: MobileUiTokens.mutedInk),
    suffixIcon: suffixIcon,
  );

  MobileStatusTone _messageTone() {
    if (_reviewIsStale) return MobileStatusTone.warning;
    if (_message.startsWith('Access active on this phone.')) {
      return MobileStatusTone.positive;
    }
    if (_message.startsWith('Submitted.') ||
        _message.startsWith('Draft saved') ||
        _message.startsWith('Saved draft restored') ||
        _message.startsWith('If an account exists') ||
        _message.startsWith('Checking') ||
        _message.startsWith('Submitting') ||
        _message.startsWith('Access published. Checking')) {
      return MobileStatusTone.info;
    }
    if (_message.startsWith('Approved.') ||
        _message.startsWith('Changes requested.') ||
        _message.startsWith('Access was published.') ||
        _message.startsWith('Submission incomplete.') ||
        _message.startsWith('Review status unavailable') ||
        _message.startsWith('No submitted application')) {
      return MobileStatusTone.warning;
    }
    return MobileStatusTone.error;
  }

  Future<void> _submit() async {
    if (_busy) return;
    final rawValues = {
      for (final key in _activeRequiredLabels.keys)
        key: _fields[key]!.text.trim(),
    };
    if (_affiliation == CampusAffiliation.student &&
        _hasLegacyCourseYearOnly &&
        rawValues['course']!.isNotEmpty) {
      rawValues.remove('yearLevel');
      rawValues.remove('sectionSet');
    }
    if (_validateRequiredFields(rawValues)) {
      await _submitDetails(_details);
    }
  }

  static bool _matchesPendingLink(
    ReviewApplication link, {
    required String registrationId,
    required String deviceId,
    required String publicKey,
    required String signingPublicKey,
    required int keyVersion,
  }) {
    final fields = link.fields;
    if (fields['registrationId'] != registrationId) return false;
    final linkDevice = fields['deviceId'] as String?;
    if (linkDevice == null) return true;
    return linkDevice == deviceId &&
        fields['publicKey'] == publicKey &&
        fields['signingPublicKey'] == signingPublicKey &&
        (fields['keyVersion'] as int? ?? keyVersion) == keyVersion;
  }

  Future<void> _linkLocalPhone() => _run(() async {
    final user = _user;
    final receipt = _localReceipt;
    if (user == null || receipt == null) return;
    final repo = _repository!;
    final latestApp = await repo.refreshProfile(user);
    if (!_isCurrentUser(user)) return;
    final currentLink = await repo.readLinkRequest(user);
    if (!_isCurrentUser(user)) return;
    _linkRequest = currentLink;
    if (latestApp != null && latestApp.status == 'published') {
      await _applyStatus(latestApp, syncApproval: true);
      if (_isCurrentUser(user)) {
        _message = 'This phone is already linked to your account.';
      }
      return;
    }
    if (currentLink?.status == 'linked') {
      _application = latestApp;
      try {
        await ref.read(trustDirectorySyncProvider).refresh();
      } catch (_) {}
      if (_isCurrentUser(user)) {
        _message = 'This phone is already linked to your account.';
      }
      return;
    }
    if (currentLink?.status == 'rejected') {
      _application = latestApp;
      _message = 'Phone link request was rejected by campus admin.';
      return;
    }
    if (currentLink?.status == 'replacement_required') {
      _application = latestApp;
      _message = 'A new phone replacement review is required before linking.';
      return;
    }
    final peer = await ref.read(localPeerProvider.future);
    final crypto = await ref.read(deviceCryptoIdentityProvider.future);
    final signing = await ref.read(deviceSigningIdentityProvider.future);
    if (currentLink?.status == 'pending' &&
        _matchesPendingLink(
          currentLink!,
          registrationId: receipt.registrationId,
          deviceId: peer.id,
          publicKey: crypto.encodedPublicKey,
          signingPublicKey: signing.encodedPublicKey,
          keyVersion: crypto.keyVersion,
        )) {
      _message = 'Link request is already pending campus admin approval.';
      return;
    }
    final nonceBytes = List<int>.generate(12, (_) => Random.secure().nextInt(256));
    final proof = await AccountLinkProof.createSigned(
      registrationId: receipt.registrationId,
      accountUid: user.uid,
      nonce: base64UrlEncode(nonceBytes),
      deviceId: peer.id,
      identity: crypto,
      signingIdentity: signing,
      directoryProject: receipt.directoryProject,
    );
    await repo.submitLinkRequest(user, proof);
    _linkRequest = await repo.readLinkRequest(user);
    _message =
        'Link request sent. Waiting for campus staff to match your registration.';
  });

  Future<void> _submitRecovery() => _run(() async {
    final user = _user;
    if (user == null) return;
    final schoolId = _recoverySchoolId.text.trim();
    final name = _recoveryName.text.trim();
    if (name.isEmpty || schoolId.isEmpty) {
      throw StateError('Enter your full name and student or employee ID.');
    }
    final peer = await ref.read(localPeerProvider.future);
    final crypto = await ref.read(deviceCryptoIdentityProvider.future);
    final signing = await ref.read(deviceSigningIdentityProvider.future);
    final qr = await DeviceRegistrationQr.createSigned(
      deviceId: peer.id,
      identity: crypto,
      signingIdentity: signing,
    );
    await _repository!.submitRecoveryRequest(
      user,
      affiliation: _affiliation,
      schoolId: schoolId,
      displayName: name,
      deviceRegistrationJson: jsonEncode(qr.toJson()),
    );
    _recoveryRequest = await _repository!.readRecoveryRequest(user);
    _showRecoveryForm = false;
    _message = 'Recovery request sent. Campus staff will review your ID.';
  });

  Future<void> _submitDetails(Map<String, String> details) => _run(() async {
    final user = _user!;
    final repository = _repository!;
    final correction = _correction;
    final existingBinding = _device;
    final peer = ref.read(localPeerProvider.future);
    final crypto = ref.read(deviceCryptoIdentityProvider.future);
    final signing = ref.read(deviceSigningIdentityProvider.future);
    final registration = await DeviceRegistrationQr.createSigned(
      deviceId: (await peer).id,
      identity: await crypto,
      signingIdentity: await signing,
    );
    final binding = jsonEncode(registration.toJson());
    if (existingBinding != null && existingBinding != binding) {
      throw StateError('This draft belongs to different device keys.');
    }
    _device = binding;
    _locked = true;
    await repository.saveDraft(user.uid, {
      ...details,
      'deviceRegistration': binding,
      'submitted': false,
      'correctionRevision': correction?.updateTime,
    });
    if (mounted) setState(() => _message = 'Submitting application…');
    if (repository.auth.currentUser?.uid != user.uid) return;
    if (correction == null) {
      await repository.submit(user, {
        ...details,
        'status': 'submitted',
        'deviceRegistration': binding,
      });
    } else {
      await repository.resubmit(user, correction, details);
      _correction = null;
      _application = null;
    }
    _submitted = true;
    await repository.saveDraft(user.uid, {
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
    _recoverySchoolId.dispose();
    _recoveryName.dispose();
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
    backgroundColor: MobileUiTokens.canvas,
    appBar: buildMobileAppBar(
      title: pilotRegistrationIsLive
          ? 'DNSC registration'
          : 'DNSC test registration',
    ),
    bottomNavigationBar: widget.onContinue == null
        ? null
        : DecoratedBox(
            decoration: const BoxDecoration(
              color: MobileUiTokens.canvas,
              border: Border(
                top: BorderSide(color: MobileUiTokens.subtleDivider),
              ),
            ),
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: OutlinedButton(
                style: MobileButtonStyles.secondaryOutlined,
                onPressed: widget.onContinue,
                child: Text(
                  _user == null && !_navigationLocked
                      ? 'Continue without an account'
                      : 'Continue to Home',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BrandHeader(
                showFirstRunGuidance: widget.onContinue != null,
                isLocalTest: !pilotRegistrationIsLive,
              ),
              if (_busy) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: const LinearProgressIndicator(
                    minHeight: 4,
                    color: MobileUiTokens.brandRed,
                    backgroundColor: MobileUiTokens.redTint,
                  ),
                ),
              ],
              if (_navigationLocked && widget.onContinue != null) ...[
                const SizedBox(height: 10),
                MobileStatusBanner(
                  tone: MobileStatusTone.info,
                  icon: Icons.sos_rounded,
                  message: _user == null
                      ? 'You can open Home for SOS now. Your account may still sign in when the request finishes.'
                      : 'You can open Home for SOS while your application finishes sending.',
                ),
              ],
              if (_message.isNotEmpty) ...[
                const SizedBox(height: 10),
                MobileStatusBanner(
                  liveRegion: true,
                  tone: _messageTone(),
                  title: _reviewIsStale ? 'Last known status' : null,
                  message: _reviewIsStale
                      ? '$_message\nConnect to check for updates.'
                      : _message,
                ),
              ],
              if (_restoreFailed) ...[
                const SizedBox(height: 14),
                FilledButton(
                  style: MobileButtonStyles.primaryFilled,
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() {
                            _busy = true;
                            _restoreFailed = false;
                            _message = '';
                          });
                          _restore();
                        },
                  child: const Text('Retry'),
                ),
              ],
              if (!_restoreFailed && _repository != null && _user == null) ...[
                const SizedBox(height: 12),
                _AuthModeSwitch(
                  creatingAccount: _createAccount,
                  enabled: !_busy,
                  onChanged: _setCreateAccount,
                ),
                const SizedBox(height: 10),
                _buildAuthCard(),
              ],
              if (!_restoreFailed && _user != null) ...[
                const SizedBox(height: 16),
                _buildSignedInHeader(),
                if (_submitted) ...[
                  const SizedBox(height: 14),
                  _buildSubmittedCard(),
                ] else if (_application == null && _localReceipt != null) ...[
                  const SizedBox(height: 14),
                  _buildLinkPhoneCard(),
                ] else if (_application == null &&
                    (_recoveryRequest != null || _showRecoveryForm)) ...[
                  const SizedBox(height: 14),
                  _buildRecoveryCard(),
                ] else ...[
                  if (_locked || _correction != null) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      style: MobileButtonStyles.secondaryOutlined,
                      onPressed: _busy ? null : _refreshStatus,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Check review status'),
                    ),
                  ],
                  const SizedBox(height: 14),
                  _buildApplicationCard(),
                  if (_application == null && !_locked) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      style: MobileButtonStyles.secondaryOutlined,
                      onPressed: _busy
                          ? null
                          : () => setState(() => _showRecoveryForm = true),
                      icon: const Icon(Icons.phonelink_setup_rounded, size: 18),
                      label: const Text('Recover registration'),
                    ),
                  ],
                ],
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Widget _buildAuthCard() => MobileSectionCard(
    padding: const EdgeInsets.all(16),
    child: AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              _createAccount ? 'Create a DNSC account' : 'Sign in to DNSC',
              style: MobileUiTokens.pageTitle,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _createAccount
                ? 'Create an account first, then submit your campus details for review.'
                : 'Use your DNSC account email to check or request campus access.',
            style: MobileUiTokens.subtitle,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _email,
            focusNode: _requiredFocusNodes['email'],
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            textInputAction: TextInputAction.next,
            onChanged: (value) => _clearFieldError('email', value.trim()),
            decoration: _requiredDecoration(
              'email',
              'Email',
              icon: Icons.email_outlined,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            focusNode: _requiredFocusNodes['password'],
            enabled: !_busy,
            obscureText: !_showPassword,
            autofillHints: [
              _createAccount
                  ? AutofillHints.newPassword
                  : AutofillHints.password,
            ],
            onSubmitted: (_) => _authenticate(create: _createAccount),
            onChanged: (value) => _clearFieldError('password', value),
            decoration: _requiredDecoration(
              'password',
              'Password',
              icon: Icons.lock_outline_rounded,
              suffixIcon: IconButton(
                tooltip: _showPassword ? 'Hide password' : 'Show password',
                onPressed: _busy
                    ? null
                    : () => setState(() => _showPassword = !_showPassword),
                icon: Icon(
                  _showPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: MobileUiTokens.mutedInk,
                ),
              ),
            ),
          ),
          if (!_createAccount)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                style: MobileButtonStyles.neutralText,
                onPressed: _busy ? null : _resetPassword,
                child: const Text('Forgot password?'),
              ),
            )
          else
            const SizedBox(height: 14),
          FilledButton(
            key: const ValueKey('auth-submit-button'),
            style: MobileButtonStyles.primaryFilled,
            onPressed: _busy
                ? null
                : () => _authenticate(create: _createAccount),
            child: _busy
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(_createAccount ? 'Create account' : 'Sign in'),
                    ],
                  )
                : Text(_createAccount ? 'Create account' : 'Sign in'),
          ),
        ],
      ),
    ),
  );

  Widget _buildSignedInHeader() {
    final email = _user?.email;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: MobileUiTokens.warmSurface,
        borderRadius: BorderRadius.circular(MobileUiTokens.controlRadius),
        border: Border.all(color: MobileUiTokens.border),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: MobileUiTokens.border),
            ),
            alignment: Alignment.center,
            child: const ExcludeSemantics(
              child: Icon(
                Icons.person_rounded,
                size: 20,
                color: MobileUiTokens.neutralIcon,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Signed in', style: MobileUiTokens.eyebrow),
                const SizedBox(height: 2),
                Text(
                  email != null && email.isNotEmpty ? email : 'DNSC account',
                  style: MobileUiTokens.bodyStrong.copyWith(fontSize: 14),
                ),
              ],
            ),
          ),
          TextButton(
            style: MobileButtonStyles.neutralText,
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _repository!.auth.signOut();
                    await _loadUser();
                  }),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmittedCard() => MobileSectionCard(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: MobileStatusBadge(
            label: 'Application status',
            tone: MobileStatusTone.info,
            icon: Icons.verified_user_outlined,
          ),
        ),
        const SizedBox(height: 10),
        const Text('Campus access review', style: MobileUiTokens.sectionHeading),
        const SizedBox(height: 4),
        const Text(
          'Refresh when online to check approval updates or sync phone access.',
          style: MobileUiTokens.subtitle,
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          style: MobileButtonStyles.secondaryOutlined,
          onPressed: _busy ? null : _refreshStatus,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Check review status'),
        ),
      ],
    ),
  );

  Widget _buildApplicationCard() => MobileSectionCard(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: MobileStatusBadge(
            label: _correction == null
                ? 'Step 2 of 2 · Campus access'
                : 'Action needed · Update details',
            tone: _correction == null
                ? MobileStatusTone.info
                : MobileStatusTone.warning,
            icon: _correction == null
                ? Icons.assignment_outlined
                : Icons.edit_note_rounded,
          ),
        ),
        const SizedBox(height: 10),
        Semantics(
          header: true,
          child: Text(
            _correction == null
                ? 'Request campus access'
                : 'Update your application',
            style: MobileUiTokens.pageTitle,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'The campus administrator reviews your details after you submit.',
          style: MobileUiTokens.subtitle,
        ),
        const SizedBox(height: 18),
        const MobileSectionLabel('Affiliation'),
        SegmentedButton<CampusAffiliation>(
          segments: const [
            ButtonSegment(
              value: CampusAffiliation.student,
              label: Text('Student'),
            ),
            ButtonSegment(
              value: CampusAffiliation.staff,
              label: Text('Staff'),
            ),
          ],
          selected: {_affiliation},
          onSelectionChanged: _busy || _locked
              ? null
              : (selection) => setState(() {
                  _affiliation = selection.single;
                  _missingFields.clear();
                }),
        ),
        const SizedBox(height: 16),
        const MobileSectionLabel('Required details'),
        for (final entry in _activeRequiredLabels.entries) ...[
          TextField(
            controller: _fields[entry.key],
            focusNode: _requiredFocusNodes[entry.key],
            enabled: !_busy && !_locked,
            maxLength: 100,
            textInputAction: TextInputAction.next,
            onChanged: (value) {
              if (entry.key == 'yearLevel' || entry.key == 'sectionSet') {
                _hasLegacyCourseYearOnly = false;
              }
              _clearFieldError(entry.key, value.trim());
            },
            decoration: _requiredDecoration(
              entry.key,
              entry.value,
              icon: _fieldIcons[entry.key],
            ),
          ),
          const SizedBox(height: 10),
        ],
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: MobileTileDivider(),
        ),
        const MobileSectionLabel('Optional contact details'),
        for (final entry in _optionalDetailLabels.entries) ...[
          TextField(
            controller: _fields[entry.key],
            enabled: !_busy && !_locked,
            maxLength: entry.key == 'address' ? 200 : 100,
            keyboardType: entry.key == 'phone'
                ? TextInputType.phone
                : TextInputType.streetAddress,
            onChanged: (value) => _clearFieldError(entry.key, value.trim()),
            decoration: MobileInputStyles.decoration(
              labelText: entry.value,
              prefixIcon: Icon(
                _fieldIcons[entry.key],
                size: 20,
                color: MobileUiTokens.mutedInk,
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 8),
        FilledButton(
          style: MobileButtonStyles.primaryFilled,
          onPressed: _busy ? null : _submit,
          child: Text(_locked ? 'Retry submission' : 'Submit for review'),
        ),
        if (!_locked) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: MobileButtonStyles.secondaryOutlined,
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _save();
                    _message = 'Draft saved on this phone.';
                  }),
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save draft'),
          ),
        ],
      ],
    ),
  );

  Widget _buildLinkPhoneCard() {
    final status = _linkRequest?.status;
    final waiting = status == 'pending';
    return MobileSectionCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: MobileStatusBadge(
              label: 'Phone approved offline',
              tone: MobileStatusTone.positive,
              icon: Icons.verified_rounded,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Link this phone to my account',
            style: MobileUiTokens.sectionHeading,
          ),
          const SizedBox(height: 4),
          Text(
            waiting
                ? 'Waiting for campus sync. Check status after the admin PC reconnects.'
                : 'Send proof from this approved phone to connect it to your DNSC account.',
            style: MobileUiTokens.subtitle,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: MobileButtonStyles.primaryFilled,
            onPressed: _busy ? null : _linkLocalPhone,
            icon: const Icon(Icons.link_rounded, size: 18),
            label: Text(
              waiting ? 'Waiting for campus sync · Retry' : 'Link this phone to my account',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecoveryCard() {
    final submitted = _recoveryRequest?.status == 'submitted';
    return MobileSectionCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Recover registration',
            style: MobileUiTokens.sectionHeading,
          ),
          const SizedBox(height: 4),
          Text(
            submitted
                ? 'Your recovery request was sent. Campus staff will verify your ID and retire your old phone.'
                : 'Lost or cleared your approved phone? Enter your name and campus ID to recover access.',
            style: MobileUiTokens.subtitle,
          ),
          if (!submitted) ...[
            const SizedBox(height: 14),
            SegmentedButton<CampusAffiliation>(
              segments: const [
                ButtonSegment(
                  value: CampusAffiliation.student,
                  label: Text('Student'),
                ),
                ButtonSegment(
                  value: CampusAffiliation.staff,
                  label: Text('Staff'),
                ),
              ],
              selected: {_affiliation},
              onSelectionChanged: (sel) =>
                  setState(() => _affiliation = sel.single),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _recoveryName,
              enabled: !_busy,
              decoration: MobileInputStyles.decoration(labelText: 'Full name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _recoverySchoolId,
              enabled: !_busy,
              decoration: MobileInputStyles.decoration(
                labelText: _affiliation == CampusAffiliation.staff
                    ? 'Employee ID'
                    : 'Student number',
              ),
            ),
            const SizedBox(height: 14),
            FilledButton(
              style: MobileButtonStyles.primaryFilled,
              onPressed: _busy ? null : _submitRecovery,
              child: const Text('Submit recovery request'),
            ),
            const SizedBox(height: 8),
            TextButton(
              style: MobileButtonStyles.neutralText,
              onPressed: _busy
                  ? null
                  : () => setState(() => _showRecoveryForm = false),
              child: const Text('Back to new registration'),
            ),
          ] else ...[
            const SizedBox(height: 14),
            OutlinedButton.icon(
              style: MobileButtonStyles.secondaryOutlined,
              onPressed: _busy ? null : _refreshStatus,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Check recovery status'),
            ),
          ],
        ],
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader({
    required this.showFirstRunGuidance,
    required this.isLocalTest,
  });

  final bool showFirstRunGuidance;
  final bool isLocalTest;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MobileUiTokens.warmSurface,
        borderRadius: BorderRadius.circular(MobileUiTokens.cardRadius),
        border: Border.all(color: MobileUiTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: MobileUiTokens.border),
                ),
                child: ExcludeSemantics(
                  child: Image.asset(
                    'assets/auth/shadownetwork_logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.hub_rounded,
                      color: MobileUiTokens.brandRed,
                      size: 28,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text(
                          'ShadowNetwork',
                          style: TextStyle(
                            fontFamily: MobileUiTokens.fontFamily,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                            color: MobileUiTokens.ink,
                          ),
                        ),
                        if (isLocalTest)
                          const MobileStatusBadge(
                            label: 'Local test',
                            tone: MobileStatusTone.warning,
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'DNSC Campus Access',
                      style: MobileUiTokens.subtitle,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (showFirstRunGuidance) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: MobileTileDivider(),
            ),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: ExcludeSemantics(
                    child: Icon(
                      Icons.sos_rounded,
                      size: 18,
                      color: MobileUiTokens.brandRed,
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sign in or create an account to request DNSC access. '
                    'You can send an SOS right away, even without an account. '
                    'To register later or check your status, open Profile.',
                    style: MobileUiTokens.subtitle,
                  ),
                ),
              ],
            ),
          ],
          if (isLocalTest) ...[
            const SizedBox(height: 8),
            const Text(
              'Use synthetic details for this local test.',
              style: MobileUiTokens.subtitle,
            ),
          ],
        ],
      ),
    );
  }
}

class _AuthModeSwitch extends StatelessWidget {
  const _AuthModeSwitch({
    required this.creatingAccount,
    required this.enabled,
    required this.onChanged,
  });

  final bool creatingAccount;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: MobileUiTokens.warmSurface,
        borderRadius: BorderRadius.circular(MobileUiTokens.controlRadius),
        border: Border.all(color: MobileUiTokens.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ModeSegment(
              key: const ValueKey('auth-mode-signin'),
              label: 'Sign in',
              selected: !creatingAccount,
              enabled: enabled,
              animate: animate,
              onTap: () => onChanged(false),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _ModeSegment(
              key: const ValueKey('auth-mode-signup'),
              label: 'Create account',
              selected: creatingAccount,
              enabled: enabled,
              animate: animate,
              onTap: () => onChanged(true),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeSegment extends StatelessWidget {
  const _ModeSegment({
    super.key,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.animate,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final bool animate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(
      color: selected ? Colors.white : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      boxShadow: selected
          ? [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 6,
                offset: const Offset(0, 1),
              ),
            ]
          : null,
    );
    final child = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Center(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: MobileUiTokens.fontFamily,
              fontSize: 14,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? MobileUiTokens.ink : MobileUiTokens.mutedInk,
            ),
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: enabled ? onTap : null,
          child: animate
              ? AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  decoration: decoration,
                  child: child,
                )
              : DecoratedBox(decoration: decoration, child: child),
        ),
      ),
    );
  }
}
