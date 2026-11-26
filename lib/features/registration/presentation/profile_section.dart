import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/mobile_ui_tokens.dart';
import '../../../core/widgets/mobile_ui_components.dart';
import '../../messaging/presentation/providers/local_messaging_providers.dart';
import '../../security/domain/entities/device_registration_qr.dart';
import '../../trust/data/services/trust_directory_sync_service.dart';
import '../../trust/domain/entities/approval_receipt.dart';
import '../../trust/domain/entities/device_access_profile.dart';
import '../../trust/presentation/providers/device_access_provider.dart';
import '../data/pilot_registration.dart';
import '../data/registration_review_api.dart';
import '../domain/campus_identity_fields.dart';
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
  SignedApprovalReceipt? _localReceipt;
  ReviewApplication? _linkRequest;
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
    _localReceipt = null;
    if (!mounted || registration.auth.currentUser?.uid != user?.uid) return;
    if (user == null) return;
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
    if (!mounted || registration.auth.currentUser?.uid != user.uid) return;
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
    ReviewApplication? linkRequest;
    if (application == null && _localReceipt != null) {
      try {
        linkRequest = await _registration!.readLinkRequest(user);
      } catch (_) {}
    }
    if (!mounted || _registration!.auth.currentUser?.uid != user.uid) return;
    setState(() {
      _application = application;
      _linkRequest = linkRequest;
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
    final repo = _registration!;
    final latestApp = await repo.refreshProfile(user);
    if (!mounted || repo.auth.currentUser?.uid != user.uid) return;
    final currentLink = await repo.readLinkRequest(user);
    if (!mounted || repo.auth.currentUser?.uid != user.uid) return;
    _application = latestApp;
    _linkRequest = currentLink;
    if (latestApp?.status == 'published' || currentLink?.status == 'linked') {
      final binding = latestApp?.fields['deviceRegistration'];
      if (binding is String &&
          await ref.read(registrationMatchesPhoneProvider(binding).future) &&
          mounted &&
          repo.auth.currentUser?.uid == user.uid) {
        try {
          await ref.read(trustDirectorySyncProvider).refresh();
        } catch (_) {}
      }
      _message = 'This phone is already linked to your account.';
      return;
    }
    if (currentLink?.status == 'rejected') {
      _message = 'Phone link request was rejected by campus admin.';
      return;
    }
    if (currentLink?.status == 'replacement_required') {
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
    final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
    final proof = await AccountLinkProof.createSigned(
      registrationId: receipt.registrationId,
      accountUid: user.uid,
      nonce: base64UrlEncode(nonce),
      deviceId: peer.id,
      identity: crypto,
      signingIdentity: signing,
      directoryProject: receipt.directoryProject,
    );
    await repo.submitLinkRequest(user, proof);
    _linkRequest = await repo.readLinkRequest(user);
    _message = 'Link request sent. Waiting for campus sync.';
  });

  Future<void> _requestPhoneReplacement() => _run(() async {
    final user = _user;
    final application = _application;
    if (user == null || application == null) return;
    final peer = await ref.read(localPeerProvider.future);
    final crypto = await ref.read(deviceCryptoIdentityProvider.future);
    final signing = await ref.read(deviceSigningIdentityProvider.future);
    final qr = await DeviceRegistrationQr.createSigned(
      deviceId: peer.id,
      identity: crypto,
      signingIdentity: signing,
    );
    await _registration!.submitPhoneReplacement(
      user,
      application,
      jsonEncode(qr.toJson()),
    );
    await _refresh();
    _message = 'Phone replacement request sent for admin review.';
  });

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
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: MobileUiTokens.canvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(MobileUiTokens.sheetRadius),
        ),
      ),
      builder: (_) => _ProfileEditSheet(
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

  MobileStatusTone _registrationTone(String? status, bool? matchesPhone) {
    if (_reviewIsStale) return MobileStatusTone.warning;
    return switch (status) {
      'published' when matchesPhone == true && widget.access.isApproved =>
        MobileStatusTone.positive,
      'published' when matchesPhone == false => MobileStatusTone.error,
      'rejected' => MobileStatusTone.error,
      'changes_requested' ||
      'approved_pending_publication' ||
      'published' ||
      'submitted' => MobileStatusTone.warning,
      _ => _user == null ? MobileStatusTone.info : MobileStatusTone.warning,
    };
  }

  MobileStatusTone _messageTone() {
    if (_message.startsWith('Contact details saved.') ||
        _message.startsWith('Change sent for review.')) {
      return MobileStatusTone.positive;
    }
    return MobileStatusTone.error;
  }

  String _initials(String? name) {
    if (name == null) return '';
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
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
    final parsedIdentity = CampusIdentityFields.fromFirestoreFields(fields);
    final details = {
      if (parsedIdentity.displayName.isNotEmpty)
        'Full name': parsedIdentity.displayName,
      if (parsedIdentity.affiliation == CampusAffiliation.staff) ...{
        if (parsedIdentity.employeeId.isNotEmpty)
          'Employee ID': parsedIdentity.employeeId,
        if (parsedIdentity.unit.isNotEmpty) 'Unit': parsedIdentity.unit,
      } else ...{
        if (parsedIdentity.studentNumber.isNotEmpty)
          'Student number': parsedIdentity.studentNumber,
        if (parsedIdentity.formattedCourseYear.isNotEmpty)
          'Course and year': parsedIdentity.formattedCourseYear,
      },
      if (parsedIdentity.phone.isNotEmpty) 'Phone number': parsedIdentity.phone,
      if (parsedIdentity.address.isNotEmpty) 'Address': parsedIdentity.address,
      if (_user?.email case final String email) 'Email': email,
    };
    final title = parsedIdentity.displayName.isNotEmpty
        ? parsedIdentity.displayName
        : fields['displayName'] as String?;
    final statusLabel = _registrationStatus(status, matchesPhone);
    final statusTone = _registrationTone(status, matchesPhone);
    final detailsPreview = parsedIdentity.summarySubtitle;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _OfflineAccessHeroCard(access: access),
        const SizedBox(height: 18),
        const MobileSectionLabel('DNSC account'),
        MobileSectionCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ProfileAvatar(initials: _initials(title)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title != null && title.trim().isNotEmpty
                              ? title
                              : 'Your account',
                          style: MobileUiTokens.sectionHeading,
                        ),
                        if (_user?.email case final String email
                            when email.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(email, style: MobileUiTokens.subtitle),
                        ],
                        const SizedBox(height: 8),
                        MobileStatusBadge(
                          label: _reviewIsStale
                              ? 'Last known · $statusLabel'
                              : statusLabel,
                          tone: statusTone,
                          icon: _reviewIsStale
                              ? Icons.cloud_off_rounded
                              : statusTone == MobileStatusTone.positive
                              ? Icons.check_circle_outline_rounded
                              : statusTone == MobileStatusTone.error
                              ? Icons.error_outline_rounded
                              : Icons.schedule_rounded,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (status == 'approved_pending_publication') ...[
                const SizedBox(height: 12),
                const MobileStatusBanner(
                  tone: MobileStatusTone.warning,
                  message:
                      'Campus staff still need to release phone access. Check again when online.',
                ),
              ] else if (status == 'submitted') ...[
                const SizedBox(height: 12),
                const MobileStatusBanner(
                  tone: MobileStatusTone.info,
                  message: 'Campus staff are reviewing your application.',
                ),
              ] else if (matchesPhone == false || status == 'rejected') ...[
                const SizedBox(height: 12),
                MobileStatusBanner(
                  tone: status == 'rejected'
                      ? MobileStatusTone.error
                      : MobileStatusTone.info,
                  icon: status == 'rejected'
                      ? Icons.error_outline_rounded
                      : Icons.info_outline_rounded,
                  message: matchesPhone == false
                      ? 'Clearing app data or changing phones can require a new approval. Contact campus staff to approve this installation.'
                      : 'Contact campus staff about your application.',
                ),
              ],
              if (status == 'changes_requested' &&
                  _application!.history.isNotEmpty) ...[
                const SizedBox(height: 12),
                MobileStatusBanner(
                  tone: MobileStatusTone.warning,
                  title: 'Reviewer note',
                  message:
                      _application!.history.last['reason'] as String? ?? '',
                ),
              ],
              if (_buildAccountAction(
                    status: status,
                    matchesPhone: matchesPhone,
                    access: access,
                  )
                  case final action?) ...[
                const SizedBox(height: 14),
                action,
              ],
              if (_busy) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: const LinearProgressIndicator(
                    minHeight: 4,
                    color: MobileUiTokens.brandRed,
                    backgroundColor: MobileUiTokens.redTint,
                  ),
                ),
              ],
              if (_message.isNotEmpty) ...[
                const SizedBox(height: 12),
                MobileStatusBanner(
                  liveRegion: true,
                  tone: _messageTone(),
                  message: _message,
                ),
              ],
            ],
          ),
        ),
        if (details.isNotEmpty || canEdit) ...[
          const SizedBox(height: 14),
          MobileSectionCard(
            padding: EdgeInsets.zero,
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
                splashColor: MobileUiTokens.neutralBadgeBg,
              ),
              child: ExpansionTile(
                shape: const Border(),
                collapsedShape: const Border(),
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                iconColor: MobileUiTokens.mutedInk,
                collapsedIconColor: MobileUiTokens.mutedInk,
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: MobileUiTokens.neutralBadgeBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: const ExcludeSemantics(
                    child: Icon(
                      Icons.badge_outlined,
                      size: 20,
                      color: MobileUiTokens.neutralIcon,
                    ),
                  ),
                ),
                title: const Text(
                  'Personal details',
                  style: MobileUiTokens.bodyStrong,
                ),
                subtitle: Text(
                  detailsPreview.isNotEmpty
                      ? detailsPreview
                      : 'View or update your details',
                  style: MobileUiTokens.subtitle,
                ),
                children: [
                  const MobileTileDivider(),
                  for (final entry in details.entries) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.key,
                              style: MobileUiTokens.subtitle.copyWith(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(entry.value, style: MobileUiTokens.body),
                          ],
                        ),
                      ),
                    ),
                    const MobileTileDivider(indent: 16),
                  ],
                  if (canEdit) ...[
                    MobileActionTile(
                      icon: Icons.contact_phone_outlined,
                      title: 'Edit phone and address',
                      subtitle: 'Updates your contact details right away.',
                      onTap: _busy ? null : () => _edit(identity: false),
                    ),
                    const MobileTileDivider(indent: 68),
                    MobileActionTile(
                      icon: Icons.edit_note_rounded,
                      iconColor: awaitingChange
                          ? MobileUiTokens.warningFg
                          : MobileUiTokens.neutralIcon,
                      iconBackground: awaitingChange
                          ? MobileUiTokens.warningBg
                          : MobileUiTokens.neutralBadgeBg,
                      title: 'Request an identity change',
                      subtitle: awaitingChange
                          ? 'Your request is awaiting review or publication.'
                          : changeStatus == 'rejected'
                          ? 'Your last request was declined.'
                          : 'Changes to name, student number, or course need admin approval.',
                      onTap: _busy || awaitingChange
                          ? null
                          : () => _edit(identity: true),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        const MobileSectionLabel('Account & settings'),
        MobileSectionCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              if (_user != null) ...[
                MobileActionTile(
                  icon: Icons.manage_accounts_outlined,
                  title: 'DNSC account settings',
                  subtitle: 'View registration or sign out.',
                  onTap: _busy ? null : _openRegistration,
                ),
                const MobileTileDivider(indent: 68),
              ],
              MobileActionTile(
                icon: Icons.settings_outlined,
                title: 'Settings',
                subtitle: 'Backup registration and field test tools',
                onTap: () async {
                  await Navigator.of(context).pushNamed('/settings');
                  if (mounted && _registrationEnabled) {
                    await _loadAccount();
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget? _buildAccountAction({
    required String? status,
    required bool? matchesPhone,
    required DeviceAccessProfile access,
  }) {
    if (_registrationEnabled && _user == null) {
      return FilledButton.icon(
        style: MobileButtonStyles.primaryFilled,
        onPressed: _busy ? null : _openRegistration,
        icon: const Icon(Icons.login_rounded, size: 18),
        label: const Text('Sign in or register with DNSC'),
      );
    }
    if (status == 'published' && matchesPhone == true && !access.isApproved) {
      return FilledButton.icon(
        style: MobileButtonStyles.primaryFilled,
        onPressed: _busy ? null : () => _run(() => _refresh(syncApproval: true)),
        icon: const Icon(Icons.sync_rounded, size: 18),
        label: const Text('Activate this phone'),
      );
    }
    if (status == 'changes_requested') {
      return FilledButton.icon(
        style: MobileButtonStyles.primaryFilled,
        onPressed: _busy ? null : _openRegistration,
        icon: const Icon(Icons.edit_note_rounded, size: 18),
        label: const Text('Update application'),
      );
    }
    if (status == 'published' && matchesPhone == false) {
      final replacementStatus =
          (_application?.fields['replacementRequest'] as Map?)?['status']
              as String?;
      return FilledButton.icon(
        style: MobileButtonStyles.primaryFilled,
        onPressed: _busy || replacementStatus == 'submitted'
            ? null
            : _requestPhoneReplacement,
        icon: const Icon(Icons.phonelink_setup_rounded, size: 18),
        label: Text(
          replacementStatus == 'submitted'
              ? 'Replacement pending review'
              : 'Request phone replacement',
        ),
      );
    }
    if (_user != null && status == null && _localReceipt != null) {
      final waitingSync = _linkRequest?.status == 'pending';
      return FilledButton.icon(
        style: MobileButtonStyles.primaryFilled,
        onPressed: _busy ? null : _linkLocalPhone,
        icon: const Icon(Icons.link_rounded, size: 18),
        label: Text(
          waitingSync
              ? 'Waiting for campus sync · Retry'
              : 'Link this phone to my account',
        ),
      );
    }
    if (_user != null && status == null && _draft['submitted'] != true) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            style: MobileButtonStyles.primaryFilled,
            onPressed: _busy ? null : _openRegistration,
            icon: const Icon(Icons.edit_note_rounded, size: 18),
            label: const Text('Finish registration'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: MobileButtonStyles.secondaryOutlined,
            onPressed: _busy ? null : _openRegistration,
            icon: const Icon(Icons.phonelink_setup_rounded, size: 18),
            label: const Text('Recover registration'),
          ),
        ],
      );
    }
    if (_user != null && matchesPhone != false && status != 'rejected') {
      return OutlinedButton.icon(
        style: MobileButtonStyles.secondaryOutlined,
        onPressed: _busy ? null : () => _run(() => _refresh(syncApproval: true)),
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('Check status'),
      );
    }
    return null;
  }
}

class _OfflineAccessHeroCard extends StatelessWidget {
  const _OfflineAccessHeroCard({required this.access});

  final DeviceAccessProfile access;

  @override
  Widget build(BuildContext context) {
    final (tone, icon, status, detail, pill) = switch (access.level) {
      DeviceAccessLevel.responder => (
        MobileStatusTone.positive,
        Icons.verified_user_rounded,
        '${access.roleLabel} · Active on this phone',
        'SOS, offline maps, and responder tools work without internet.',
        'Offline ready',
      ),
      DeviceAccessLevel.revoked => (
        MobileStatusTone.revoked,
        Icons.block_rounded,
        'Approval removed',
        'You can still send an SOS. Contact campus staff if you need phone approval.',
        'Revoked',
      ),
      DeviceAccessLevel.keyMismatch => (
        MobileStatusTone.error,
        Icons.key_off_rounded,
        'This phone needs approval again',
        'You can still send an SOS. Contact campus staff if you need phone approval.',
        'Action needed',
      ),
      DeviceAccessLevel.outdatedBundle => (
        MobileStatusTone.warning,
        Icons.update_rounded,
        'Phone approval expired',
        'You can still send an SOS. Contact campus staff if you need phone approval.',
        'Expired',
      ),
      DeviceAccessLevel.unregistered => (
        MobileStatusTone.warning,
        Icons.app_registration_rounded,
        'Phone approval needed',
        'You can still send an SOS. Contact campus staff if you need phone approval.',
        'Not approved',
      ),
      _ => (
        MobileStatusTone.positive,
        Icons.verified_rounded,
        '${access.roleLabel} · Active on this phone',
        'SOS, offline maps, and peer relay work without internet.',
        'Offline ready',
      ),
    };
    final palette = mobileStatusColors(tone);
    final isRevoked = tone == MobileStatusTone.revoked;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(MobileUiTokens.cardRadius),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: isRevoked
                  ? Colors.white.withValues(alpha: 0.16)
                  : Colors.white.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: ExcludeSemantics(
              child: Icon(icon, size: 22, color: palette.foreground),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'This phone’s offline access',
                      style: MobileUiTokens.eyebrow.copyWith(
                        letterSpacing: 0.3,
                        color: palette.foreground.withValues(alpha: 0.85),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isRevoked
                            ? Colors.white.withValues(alpha: 0.18)
                            : Colors.white.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        pill,
                        style: MobileUiTokens.badgeText.copyWith(
                          fontSize: 11,
                          color: palette.foreground,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  status,
                  style: MobileUiTokens.sectionHeading.copyWith(
                    color: palette.foreground,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: MobileUiTokens.subtitle.copyWith(
                    color: palette.foreground.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.initials});

  final String initials;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: MobileUiTokens.neutralBadgeBg,
        shape: BoxShape.circle,
        border: Border.all(color: MobileUiTokens.border),
      ),
      alignment: Alignment.center,
      child: ExcludeSemantics(
        child: initials.isNotEmpty
            ? Text(
                initials,
                style: const TextStyle(
                  fontFamily: MobileUiTokens.fontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: MobileUiTokens.ink,
                ),
              )
            : const Icon(
                Icons.person_outline_rounded,
                size: 24,
                color: MobileUiTokens.neutralIcon,
              ),
      ),
    );
  }
}

class _ProfileEditSheet extends StatefulWidget {
  const _ProfileEditSheet({
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
  State<_ProfileEditSheet> createState() => _ProfileEditSheetState();
}

class _ProfileEditSheetState extends State<_ProfileEditSheet> {
  static const _fieldIcons = {
    'displayName': Icons.person_outline_rounded,
    'studentNumber': Icons.badge_outlined,
    'courseYear': Icons.school_outlined,
    'phone': Icons.phone_outlined,
    'address': Icons.home_outlined,
  };

  final _form = GlobalKey<FormState>();
  late final _values = Map<String, String>.of(widget.initial);
  bool _saving = false;
  String? _error;

  bool get _hasChanges => _values.entries.any(
    (entry) => widget.initial[entry.key] != entry.value,
  );

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
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return PopScope(
      canPop: !_saving,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: ExcludeSemantics(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: MobileUiTokens.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          widget.identity
                              ? 'Request an identity change'
                              : 'Edit contact details',
                          style: MobileUiTokens.pageTitle.copyWith(fontSize: 20),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: MobileUiTokens.mutedInk,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  widget.identity
                      ? 'Changes to your name, student number, or course require campus admin review.'
                      : 'Phone number and address update your profile immediately.',
                  style: MobileUiTokens.subtitle,
                ),
                const SizedBox(height: 18),
                for (final entry in widget.labels.entries) ...[
                  TextFormField(
                    enabled: !_saving,
                    initialValue: _values[entry.key],
                    maxLength: entry.key == 'address' ? 200 : 100,
                    keyboardType: entry.key == 'phone'
                        ? TextInputType.phone
                        : entry.key == 'address'
                        ? TextInputType.streetAddress
                        : TextInputType.name,
                    decoration: MobileInputStyles.decoration(
                      labelText: entry.value,
                      prefixIcon: _fieldIcons[entry.key] == null
                          ? null
                          : Icon(
                              _fieldIcons[entry.key],
                              size: 20,
                              color: MobileUiTokens.mutedInk,
                            ),
                    ),
                    onChanged: (value) =>
                        setState(() => _values[entry.key] = value.trim()),
                    validator: (value) =>
                        widget.identity && (value ?? '').trim().isEmpty
                        ? 'Enter ${entry.value.toLowerCase()}.'
                        : null,
                  ),
                  const SizedBox(height: 12),
                ],
                if (_error case final error?) ...[
                  MobileStatusBanner(
                    liveRegion: true,
                    tone: MobileStatusTone.error,
                    message: error,
                  ),
                  const SizedBox(height: 14),
                ],
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: MobileButtonStyles.secondaryOutlined,
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        style: MobileButtonStyles.primaryFilled,
                        onPressed: _saving || !_hasChanges ? null : _save,
                        child: Text(
                          _saving
                              ? 'Saving…'
                              : widget.identity
                              ? 'Send for review'
                              : 'Save',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
