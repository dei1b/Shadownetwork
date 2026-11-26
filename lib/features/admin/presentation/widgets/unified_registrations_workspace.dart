import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadownetwork/core/widgets/action_feedback.dart';

import '../../../registration/data/hosted_publisher_client.dart';
import '../../../registration/data/registration_review_api.dart';
import '../../../registration/domain/campus_identity_fields.dart';
import '../../../security/domain/entities/device_registration_qr.dart';
import '../../../trust/domain/entities/approval_receipt.dart';
import '../../../trust/domain/entities/trust_bundle.dart';
import '../../data/desktop_admin_registry_repository.dart';
import '../../domain/entities/campus_registration.dart';
import '../../domain/entities/registered_device.dart';
import '../theme/admin_theme.dart';
import 'approval_qr_dialog.dart';
import 'registration_json_dialog.dart';

class UnifiedRegistrationsWorkspace extends StatefulWidget {
  const UnifiedRegistrationsWorkspace({
    super.key,
    this.registry,
    this.onRegistryChanged,
    this.onScanPhoneQr,
    this.reviewApi,
    this.publisherClient,
    this.validationPanel,
    this.initialSessionForTesting,
  });

  final DesktopAdminRegistryRepository? registry;
  final VoidCallback? onRegistryChanged;
  final Future<String?> Function()? onScanPhoneQr;
  final RegistrationReviewApi? reviewApi;
  final HostedPublisherClient? publisherClient;
  final Widget? validationPanel;
  final ({String token, String uid, String email})? initialSessionForTesting;

  @override
  State<UnifiedRegistrationsWorkspace> createState() =>
      _UnifiedRegistrationsWorkspaceState();
}

class _UnifiedRegistrationsWorkspaceState
    extends State<UnifiedRegistrationsWorkspace> {
  late final RegistrationReviewApi _api =
      widget.reviewApi ?? RegistrationReviewApi.live();
  late final HostedPublisherClient _publisher =
      widget.publisherClient ?? HostedPublisherClient.live();
  final TextEditingController _search = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final Map<String, String> _pendingDecisionIds = {};
  final Map<String, String> _generatedIdsByUid = {};

  bool get _hasLocalRegistry => widget.registry != null;

  bool _loading = true;
  bool _busy = false;
  String? _loadError;
  String _statusFilter = 'all';
  String _roleFilter = 'all';
  late ({String token, String uid, String email})? _session =
      widget.initialSessionForTesting;
  ReviewerProfile? _savedReviewer;

  List<CampusRegistration> _localRegistrations = [];
  List<PendingSyncOperation> _pendingSync = [];
  List<ReviewApplication> _onlineApplications = [];
  List<ReviewApplication> _remoteRegistrations = [];
  List<ReviewApplication> _linkRequests = [];
  List<ReviewApplication> _recoveryRequests = [];

  String _decisionIdFor(String registrationId) => _pendingDecisionIds.putIfAbsent(
    registrationId,
    CampusRegistration.newDecisionId,
  );

  void _clearDecisionId(String registrationId) =>
      _pendingDecisionIds.remove(registrationId);

  @override
  void initState() {
    super.initState();
    _loadLocalState();
    if (_session != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _runBusy(() => _refreshOnline(reconcile: _hasLocalRegistry));
        }
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadLocalState() async {
    final registry = widget.registry;
    if (registry == null) {
      if (!mounted) return;
      setState(() {
        _localRegistrations = [];
        _pendingSync = [];
        _savedReviewer = null;
        _loading = false;
        _loadError = null;
      });
      return;
    }
    try {
      final registrations = await registry.loadRegistrations();
      final pending = await registry.loadPendingSync();
      final reviewer = await registry.loadReviewerProfile();
      if (!mounted) return;
      setState(() {
        _localRegistrations = registrations;
        _pendingSync = pending;
        _savedReviewer = reviewer;
        if (reviewer != null && _email.text.isEmpty) {
          _email.text = reviewer.email;
        }
        _loading = false;
        _loadError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError =
            'Unable to load registrations from this computer. Check storage and retry.';
      });
    }
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on StateError catch (error) {
      _notify(error.message, kind: FeedbackKind.error);
    } on FormatException catch (error) {
      _notify(error.message, kind: FeedbackKind.error);
    } catch (_) {
      _notify(
        'Could not finish that action. Check the connection and retry.',
        kind: FeedbackKind.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notify(String message, {FeedbackKind kind = FeedbackKind.success}) {
    if (!mounted) return;
    ActionFeedback.show(context, message, kind: kind);
  }

  Future<void> _signInReviewer() => _runBusy(() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      throw StateError('Enter reviewer email and password.');
    }
    final result = await RegistrationReviewApi.signIn(email, password);
    final profile = ReviewerProfile(uid: result.uid, email: email);
    if (widget.registry != null) {
      await widget.registry!.saveReviewerProfile(profile);
    }
    if (!mounted) return;
    _password.clear();
    setState(() {
      _session = (token: result.token, uid: result.uid, email: email);
      _savedReviewer = profile;
    });
    await _refreshOnline(reconcile: true);
  });

  Future<void> _refreshOnline({bool reconcile = false}) async {
    final session = _session;
    if (session == null) return;
    final apps = await _api.list(session.token);
    List<ReviewApplication> remoteRegs = [];
    List<ReviewApplication> links = [];
    List<ReviewApplication> recoveries = [];
    try {
      remoteRegs = await _api.listCollection(
        session.token,
        'campusRegistrations',
      );
      links = await _api.listCollection(
        session.token,
        'registrationLinkRequests',
      );
      recoveries = await _api.listCollection(
        session.token,
        'registrationRecoveryRequests',
      );
    } on StateError {
      // Optional collections remain gracefully empty if project rules are older.
    }
    if (reconcile && widget.registry != null) {
      final directory = await _api.readDirectory(session.token);
      if (directory != null) {
        final published = TrustBundle.fromJsonString(directory.bundle);
        await widget.registry!.saveLastPublishedRoster(
          published,
          directory.bundle,
        );
        await widget.registry!.reconcileWithPublishedRoster(
          published,
          reviewProject,
        );
      }
    }
    await _loadLocalState();
    if (!mounted) return;
    setState(() {
      _onlineApplications = apps;
      _remoteRegistrations = remoteRegs;
      _linkRequests = links;
      _recoveryRequests = recoveries;
    });
  }

  Future<ReviewerProfile> _ensureReviewerProfile() async {
    if (_session != null) {
      return ReviewerProfile(uid: _session!.uid, email: _session!.email);
    }
    if (_savedReviewer != null && _savedReviewer!.uid.isNotEmpty) {
      return _savedReviewer!;
    }
    final uidCtrl = TextEditingController(text: 'local-admin');
    final emailCtrl = TextEditingController(text: _email.text.trim());
    final confirmed = await showDialog<ReviewerProfile>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Identify local reviewer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Record which campus administrator approves offline QR registrations on this PC.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: uidCtrl,
              decoration: const InputDecoration(labelText: 'Reviewer ID'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(labelText: 'Reviewer email'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final uid = uidCtrl.text.trim();
              final mail = emailCtrl.text.trim();
              if (uid.isEmpty || mail.isEmpty) return;
              Navigator.pop(context, ReviewerProfile(uid: uid, email: mail));
            },
            child: const Text('Save reviewer'),
          ),
        ],
      ),
    );
    uidCtrl.dispose();
    emailCtrl.dispose();
    if (confirmed == null) {
      throw StateError('Reviewer identity is required before offline approval.');
    }
    if (widget.registry != null) {
      await widget.registry!.saveReviewerProfile(confirmed);
    }
    if (mounted) setState(() => _savedReviewer = confirmed);
    return confirmed;
  }

  Future<void> _scanOrPastePhoneQr({required bool paste}) async {
    if (_busy) return;
    final String? source;
    if (paste) {
      source = await showDialog<String>(
        context: context,
        builder: (_) => const RegistrationJsonDialog(),
      );
    } else {
      source = await widget.onScanPhoneQr?.call();
    }
    if (source == null || source.trim().isEmpty || !mounted) return;
    try {
      final qr = DeviceRegistrationQr.fromJsonString(source.trim());
      await qr.verifySignature();
      if (!mounted) return;
      final existing = _findMatchingByPhoneOrName(qr);
      final now = DateTime.now().toUtc();
      final info = qr.userInformation;
      final base =
          existing ??
          CampusRegistration(
            registrationId: CampusRegistration.newRegistrationId(),
            source: CampusRegistrationSource.qr,
            status: CampusRegistrationStatus.submitted,
            syncState: CampusSyncState.waitingToSync,
            identity: CampusIdentityFields(
              displayName: info?.fullName ?? '',
              phone: info?.phoneNumber ?? '',
              address: info?.address ?? '',
            ),
            submittedSnapshot: CampusIdentityFields(
              displayName: info?.fullName ?? '',
              phone: info?.phoneNumber ?? '',
              address: info?.address ?? '',
            ),
            role: RegisteredDeviceRole.civilian,
            activePhone: RegistrationPhoneBinding(
              deviceId: qr.deviceId,
              publicKey: qr.publicKey,
              signingPublicKey: qr.signingPublicKey,
              keyId: qr.keyId,
              keyVersion: qr.keyVersion,
              deviceRegistrationJson: source.trim(),
            ),
            createdAt: now,
            updatedAt: now,
          );
      final isReplacement =
          existing != null &&
          !existing.activePhone.hasSameKeys(
            RegistrationPhoneBinding(
              deviceId: qr.deviceId,
              publicKey: qr.publicKey,
              signingPublicKey: qr.signingPublicKey,
              keyVersion: qr.keyVersion,
            ),
          );
      await _openUnifiedEditor(
        _UnifiedQueueItem(
          registration: base,
          pendingNewPhone: isReplacement
              ? RegistrationPhoneBinding(
                  deviceId: qr.deviceId,
                  publicKey: qr.publicKey,
                  signingPublicKey: qr.signingPublicKey,
                  keyId: qr.keyId,
                  keyVersion: qr.keyVersion,
                  deviceRegistrationJson: source.trim(),
                )
              : null,
        ),
      );
    } on FormatException catch (error) {
      _notify(error.message, kind: FeedbackKind.error);
    } catch (_) {
      _notify(
        'Could not verify the phone registration QR.',
        kind: FeedbackKind.error,
      );
    }
  }

  CampusRegistration? _findMatchingByPhoneOrName(DeviceRegistrationQr qr) {
    for (final reg in _localRegistrations) {
      if (reg.activePhone.deviceId.toLowerCase() == qr.deviceId.toLowerCase()) {
        return reg;
      }
    }
    return null;
  }

  List<_UnifiedQueueItem> _buildUnifiedQueue() {
    final byRegId = <String, _UnifiedQueueItem>{};
    final byAccountUid = <String, String>{};
    final byDeviceId = <String, String>{};

    for (final reg in _localRegistrations) {
      byRegId[reg.registrationId] = _UnifiedQueueItem(registration: reg);
      if (reg.accountUid != null && reg.accountUid!.isNotEmpty) {
        byAccountUid[reg.accountUid!] = reg.registrationId;
      }
      if (reg.activePhone.deviceId.isNotEmpty) {
        byDeviceId[reg.activePhone.deviceId.toLowerCase()] = reg.registrationId;
      }
    }

    for (final app in _onlineApplications) {
      final regIdFromApp = app.fields['registrationId'] as String?;
      final phoneId = _extractDeviceId(app.fields['deviceRegistration']);
      final existingKey =
          (regIdFromApp != null && byRegId.containsKey(regIdFromApp))
          ? regIdFromApp
          : byAccountUid[app.id] ??
                (phoneId == null ? null : byDeviceId[phoneId.toLowerCase()]);
      final reg = _registrationFromApplication(
        app,
        existing: existingKey == null ? null : byRegId[existingKey]?.registration,
        generatedId: existingKey ?? regIdFromApp,
      );
      byRegId[reg.registrationId] = _UnifiedQueueItem(
        registration: reg,
        onlineApplication: app,
      );
      byAccountUid[app.id] = reg.registrationId;
      if (reg.activePhone.deviceId.isNotEmpty) {
        byDeviceId[reg.activePhone.deviceId.toLowerCase()] = reg.registrationId;
      }
    }

    for (final remote in _remoteRegistrations) {
      final regId = (remote.fields['registrationId'] as String? ?? remote.id).trim();
      if (regId.isEmpty || byRegId.containsKey(regId)) continue;
      final accUid = (remote.fields['accountUid'] as String?)?.trim();
      if (accUid != null && accUid.isNotEmpty && byAccountUid.containsKey(accUid)) {
        continue;
      }
      final identity = CampusIdentityFields.fromFirestoreFields(remote.fields);
      final role = RegisteredDeviceRole.fromCode(remote.fields['role'] as String?);
      final status = CampusRegistrationStatus.fromCode(remote.fields['status'] as String?);
      final phoneId = (remote.fields['deviceId'] as String? ?? '').trim();
      final reg = CampusRegistration(
        registrationId: regId,
        source: CampusRegistrationSource.fromCode(remote.fields['source'] as String?),
        status: status,
        syncState: CampusSyncState.synced,
        accountUid: accUid?.isEmpty == true ? null : accUid,
        identity: identity,
        submittedSnapshot: identity,
        role: role,
        activePhone: RegistrationPhoneBinding(
          deviceId: phoneId,
          publicKey: remote.fields['publicKey'] as String?,
          signingPublicKey: remote.fields['signingPublicKey'] as String?,
          keyVersion: (remote.fields['keyVersion'] as int?) ?? 1,
          deviceRegistrationJson: remote.fields['deviceRegistration'] as String?,
        ),
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.tryParse(remote.fields['updatedAt'] as String? ?? '')?.toUtc() ??
            DateTime.now().toUtc(),
        remoteUpdateTime: remote.updateTime,
      );
      byRegId[reg.registrationId] = _UnifiedQueueItem(registration: reg);
      if (accUid != null && accUid.isNotEmpty) {
        byAccountUid[accUid] = reg.registrationId;
      }
      if (phoneId.isNotEmpty) {
        byDeviceId[phoneId.toLowerCase()] = reg.registrationId;
      }
    }

    for (final link in _linkRequests) {
      if (link.fields['status'] != 'pending') continue;
      final regId = (link.fields['registrationId'] as String? ?? '').trim();
      final item = byRegId[regId];
      if (item != null) {
        byRegId[regId] = item.copyWith(linkRequest: link);
      }
    }

    for (final rec in _recoveryRequests) {
      if (rec.fields['status'] != 'submitted') continue;
      final schoolId = (rec.fields['schoolId'] as String? ?? '')
          .trim()
          .toLowerCase();
      String? targetId = byAccountUid[rec.id];
      if (targetId == null && schoolId.isNotEmpty) {
        for (final entry in byRegId.entries) {
          if (entry.value.registration.identity.schoolId.toLowerCase() ==
              schoolId) {
            targetId = entry.key;
            break;
          }
        }
      }
      if (targetId != null && byRegId[targetId] != null) {
        byRegId[targetId] = byRegId[targetId]!.copyWith(recoveryRequest: rec);
      }
    }

    final query = _search.text.trim().toLowerCase();
    return byRegId.values.where((item) {
      final r = item.registration;
      if (_roleFilter != 'all' && r.role.name != _roleFilter) return false;
      final statusMatches = switch (_statusFilter) {
        'needs_review' =>
          r.status == CampusRegistrationStatus.submitted ||
              r.status == CampusRegistrationStatus.approvedPendingPublication ||
              item.linkRequest != null ||
              item.recoveryRequest != null ||
              (item.onlineApplication?.fields['replacementRequest']
                      as Map?)?['status'] ==
                  'submitted' ||
              item.onlineApplication?.profileChange?['status'] == 'submitted',
        'waiting_sync' => r.syncState == CampusSyncState.waitingToSync,
        'published' => r.status == CampusRegistrationStatus.published,
        'changes_requested' =>
          r.status == CampusRegistrationStatus.changesRequested,
        'rejected' => r.status == CampusRegistrationStatus.rejected,
        'revoked' => r.status == CampusRegistrationStatus.revoked,
        'conflicts' => r.status == CampusRegistrationStatus.conflict,
        _ => true,
      };
      if (!statusMatches) return false;
      if (query.isEmpty) return true;
      return '${r.identity.displayName} ${r.identity.schoolId} '
              '${r.identity.unit} ${r.identity.formattedCourseYear} '
              '${r.accountEmail ?? ''} ${r.activePhone.deviceId} ${r.registrationId}'
          .toLowerCase()
          .contains(query);
    }).toList();
  }

  static String? _extractDeviceId(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      return DeviceRegistrationQr.fromJsonString(raw).deviceId;
    } catch (_) {
      return null;
    }
  }

  CampusRegistration _registrationFromApplication(
    ReviewApplication app, {
    CampusRegistration? existing,
    String? generatedId,
  }) {
    final fields = app.fields;
    final identity = CampusIdentityFields.fromFirestoreFields(fields);
    DeviceRegistrationQr? qr;
    final rawReg = fields['deviceRegistration'];
    if (rawReg is String && rawReg.isNotEmpty) {
      try {
        qr = DeviceRegistrationQr.fromJsonString(rawReg);
      } catch (_) {}
    }
    final assignedRole = app.history.isEmpty
        ? existing?.role ?? RegisteredDeviceRole.civilian
        : RegisteredDeviceRole.fromCode(
            app.history.last['role'] as String? ?? existing?.role.name,
          );
    final status = switch (app.status) {
      'approved_pending_publication' =>
        CampusRegistrationStatus.approvedPendingPublication,
      'published' => CampusRegistrationStatus.published,
      'changes_requested' => CampusRegistrationStatus.changesRequested,
      'rejected' => CampusRegistrationStatus.rejected,
      _ => CampusRegistrationStatus.submitted,
    };
    final now = DateTime.now().toUtc();
    return CampusRegistration(
      registrationId:
          generatedId ??
          existing?.registrationId ??
          _generatedIdsByUid.putIfAbsent(
            app.id,
            CampusRegistration.newRegistrationId,
          ),
      source: existing?.source ?? CampusRegistrationSource.online,
      status: existing?.status == CampusRegistrationStatus.conflict
          ? CampusRegistrationStatus.conflict
          : existing?.status == CampusRegistrationStatus.revoked
          ? CampusRegistrationStatus.revoked
          : status,
      syncState: existing?.syncState ?? CampusSyncState.synced,
      conflictReason: existing?.conflictReason,
      accountUid: app.id,
      accountEmail: existing?.accountEmail,
      identity: identity,
      submittedSnapshot: existing?.submittedSnapshot ?? identity,
      role: assignedRole,
      activePhone: qr == null
          ? existing?.activePhone ?? const RegistrationPhoneBinding(deviceId: '')
          : RegistrationPhoneBinding(
              deviceId: qr.deviceId,
              publicKey: qr.publicKey,
              signingPublicKey: qr.signingPublicKey,
              keyId: qr.keyId,
              keyVersion: qr.keyVersion,
              deviceRegistrationJson: rawReg as String,
            ),
      retiredKeys: existing?.retiredKeys ?? const [],
      reviewHistory: existing?.reviewHistory ?? const [],
      revision: (fields['revision'] as int?) ?? 0,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      remoteUpdateTime: app.updateTime,
    );
  }

  Future<void> _syncPendingDecisions() => _runBusy(() async {
    final registry = widget.registry;
    final session = _session;
    if (registry == null) return;
    if (session == null) {
      throw StateError('Sign in first to sync pending campus decisions.');
    }
    await _refreshOnline(reconcile: true);
    final pending = await registry.loadPendingSync();
    if (pending.isEmpty) {
      _notify('No pending offline approvals to sync.');
      return;
    }

    var synced = 0;
    if (_publisher.isConfigured) {
      for (final op in pending) {
        final reg = _localRegistrations
            .where((r) => r.registrationId == op.registrationId)
            .firstOrNull;
        if (reg == null || reg.status == CampusRegistrationStatus.conflict) {
          continue;
        }
        final publishedReg = reg.copyWith(
          status: reg.status == CampusRegistrationStatus.revoked
              ? CampusRegistrationStatus.revoked
              : CampusRegistrationStatus.published,
          syncState: CampusSyncState.synced,
          updatedAt: DateTime.now().toUtc(),
        );
        final res = await _publisher.publishDecision(
          token: session.token,
          payload: {
            'action': 'sync_offline_decision',
            'decisionId': op.decisionId,
            'registrationId': publishedReg.registrationId,
            if (publishedReg.accountUid != null)
              'accountUid': publishedReg.accountUid,
            'role': publishedReg.role.name,
            'targetStatus': publishedReg.status.code,
            'overrideConflict': op.kind == PendingSyncKind.publishRevocationCorrection,
            'reviewedFields': publishedReg.identity.toFirestoreFields(),
            'registration': {
              'registrationId': publishedReg.registrationId,
              'source': publishedReg.source.name,
              'status': reg.status.code,
              if (publishedReg.accountUid != null)
                'accountUid': publishedReg.accountUid,
              'deviceRegistration': publishedReg.activePhone.deviceRegistrationJson,
              ...publishedReg.identity.toFirestoreFields(),
            },
          },
        );
        if (res.bundle != null && res.bundle!.trim().isNotEmpty) {
          await registry.saveLastPublishedRoster(
            TrustBundle.fromJsonString(res.bundle!),
            res.bundle!,
          );
        }
        await registry.saveRegistration(
          publishedReg,
          removePendingForRegistration: true,
        );
        await registry.removePendingSync(op.decisionId);
        synced++;
      }
    } else {
      final directory = await _api.readDirectory(session.token);
      final remoteRegs = await _api.listCollection(
        session.token,
        'campusRegistrations',
      );
      final remoteMap = {for (final r in remoteRegs) r.id: r};
      var currentVersion = directory?.version ?? 0;
      var currentUpdateTime = directory?.updateTime;

      for (final op in pending) {
        final reg = _localRegistrations
            .where((r) => r.registrationId == op.registrationId)
            .firstOrNull;
        if (reg == null || reg.status == CampusRegistrationStatus.conflict) {
          continue;
        }
        final devices = await registry.loadDevices();
        final bundleJson = await registry.buildTrustBundleJson(
          devices,
          directoryProject: reviewProject,
          minimumPreviousVersion: currentVersion,
        );
        final parsedBundle = TrustBundle.fromJsonString(bundleJson);
        final publishedReg = reg.copyWith(
          status: reg.status == CampusRegistrationStatus.revoked
              ? CampusRegistrationStatus.revoked
              : CampusRegistrationStatus.published,
          syncState: CampusSyncState.synced,
          updatedAt: DateTime.now().toUtc(),
        );
        await _api.publishCampusRegistration(
          session.token,
          registration: publishedReg,
          version: parsedBundle.bundleVersion,
          bundle: bundleJson,
          directoryUpdateTime: currentUpdateTime,
          remoteRegistrationUpdateTime: remoteMap[reg.registrationId]?.updateTime,
        );
        await registry.saveLastPublishedRoster(parsedBundle, bundleJson);
        await registry.saveRegistration(
          publishedReg,
          removePendingForRegistration: true,
        );
        await registry.removePendingSync(op.decisionId);
        currentVersion = parsedBundle.bundleVersion;
        final refreshed = await _api.readDirectory(session.token);
        currentUpdateTime = refreshed?.updateTime;
        synced++;
      }
    }
    await _refreshOnline();
    widget.onRegistryChanged?.call();
    _notify('Synced $synced offline registration decision(s) to campus directory.');
  });

  Future<void> _showDirectoryQr() async {
    final registry = widget.registry;
    if (registry == null) return;
    ({int version, String bundleJson})? payload;
    await _runBusy(() async {
      final devices = await registry.loadDevices();
      final bundleJson = await registry.buildTrustBundleJson(
        devices,
        directoryProject: reviewProject.isEmpty ? null : reviewProject,
      );
      final bundle = TrustBundle.fromJsonString(bundleJson);
      payload = (version: bundle.bundleVersion, bundleJson: bundleJson);
    });
    if (payload == null || !mounted) return;
    await showApprovalQrDialog(
      context,
      title: 'Scan approval QR · v${payload!.version}',
      payloadJson: payload!.bundleJson,
    );
  }

  Future<void> _copyTrustBundle() => _runBusy(() async {
    final registry = widget.registry;
    if (registry == null) return;
    final devices = await registry.loadDevices();
    final bundleJson = await registry.buildTrustBundleJson(
      devices,
      directoryProject: reviewProject.isEmpty ? null : reviewProject,
    );
    final parsed = TrustBundle.fromJsonString(bundleJson);
    await Clipboard.setData(ClipboardData(text: bundleJson));
    _notify('Signed trust bundle v${parsed.bundleVersion} copied to clipboard.');
  });

  Future<void> _openUnifiedEditor(_UnifiedQueueItem item) async {
    final result = await showDialog<_EditorOutcome>(
      context: context,
      builder: (_) => _UnifiedRegistrationEditorDialog(
        item: item,
        hasOnlineSession: _session != null,
        hasLocalRegistry: _hasLocalRegistry,
        sessionUid: _session?.uid ?? _savedReviewer?.uid,
      ),
    );
    if (result == null || !mounted) return;

    ({String title, String packageJson})? approvalQr;
    await _runBusy(() async {
      final registry = widget.registry;
      final registration = item.registration;
      switch (result.action) {
        case _EditorAction.approveOffline:
          if (registry == null) return;
          final reviewer = await _ensureReviewerProfile();
          final approved = await registry.approveOfflineRegistration(
            registration: registration,
            reviewer: reviewer,
            role: result.role,
            reviewedIdentity: result.identity,
            reason: result.reason,
            directoryProject: reviewProject.isEmpty ? null : reviewProject,
          );
          await _loadLocalState();
          widget.onRegistryChanged?.call();
          _notify(
            'Approved on this PC · waiting to sync. Show the QR to the phone.',
          );
          approvalQr = (
            title: 'Approval QR · ${approved.registration.identity.displayName}',
            packageJson: approved.packageJson,
          );
          break;
        case _EditorAction.approveAndPublishOnline:
          final session = _session!;
          final onlineApp = item.onlineApplication;
          if (onlineApp != null && onlineApp.id == session.uid) {
            throw StateError('Another reviewer must approve your registration.');
          }
          final snapshot = registration.submittedSnapshot ?? registration.identity;
          final edited = result.identity.diffKeysFrom(snapshot);
          final decisionId = _decisionIdFor(registration.registrationId);
          if (_publisher.isConfigured) {
            final res = await _publisher.publishDecision(
              token: session.token,
              payload: {
                'action': onlineApp != null
                    ? 'approve_online'
                    : 'sync_offline_decision',
                'decisionId': decisionId,
                'registrationId': registration.registrationId,
                if (onlineApp != null) 'accountUid': onlineApp.id,
                'role': result.role.name,
                'reason': result.reason,
                'reviewedFields': result.identity.toFirestoreFields(),
                if (edited.isNotEmpty) 'editedFields': edited,
                if (onlineApp == null)
                  'registration': {
                    'registrationId': registration.registrationId,
                    'source': registration.source.name,
                    'status': registration.status.code,
                    if (registration.accountUid != null)
                      'accountUid': registration.accountUid,
                    'deviceRegistration':
                        registration.activePhone.deviceRegistrationJson,
                    ...result.identity.toFirestoreFields(),
                  },
              },
            );
            _clearDecisionId(registration.registrationId);
            if (registry != null) {
              if (res.bundle != null && res.bundle!.trim().isNotEmpty) {
                await registry.saveLastPublishedRoster(
                  TrustBundle.fromJsonString(res.bundle!),
                  res.bundle!,
                );
              }
              await registry.saveRegistration(
                registration.copyWith(
                  identity: result.identity,
                  role: result.role,
                  status: CampusRegistrationStatus.published,
                  syncState: CampusSyncState.synced,
                  updatedAt: DateTime.now().toUtc(),
                ),
                removePendingForRegistration: true,
              );
            }
            await _refreshOnline();
            widget.onRegistryChanged?.call();
            _notify('Approval published');
            break;
          }
          if (registry == null) {
            throw StateError(
              'Hosted publisher is unavailable and no local registry is present.',
            );
          }
          if (onlineApp != null) {
            if (onlineApp.status == 'submitted') {
              await _api.decide(
                session.token,
                session.uid,
                onlineApp,
                'approved_pending_publication',
                result.reason,
                role: result.role.name,
                reviewedFields: result.identity.toFirestoreFields(),
                registrationId: registration.registrationId,
                decisionId: decisionId,
                editedFields: edited.isEmpty ? null : edited,
              );
            }
            final refreshedApp = await _api.get(session.token, onlineApp.id);
            final dir = await _api.readDirectory(session.token);
            final device = registration
                .copyWith(
                  identity: result.identity,
                  role: result.role,
                  status: CampusRegistrationStatus.published,
                )
                .toRegisteredDevice();
            final source = await registry.stageDirectoryApproval(
              device,
              reviewProject,
              dir?.version ?? 0,
              publishedBundle: dir == null
                  ? null
                  : TrustBundle.fromJsonString(dir.bundle),
              assignRole: true,
              updateOwnerName: edited.contains('displayName'),
            );
            final bundle = TrustBundle.fromJsonString(source);
            if (refreshedApp != null) {
              await _api.publish(
                session.token,
                refreshedApp,
                bundle.bundleVersion,
                source,
                directoryUpdateTime: dir?.updateTime,
              );
            }
            await registry.saveLastPublishedRoster(bundle, source);
          } else {
            final reviewer = ReviewerProfile(
              uid: session.uid,
              email: session.email,
            );
            final approved = await registry.approveOfflineRegistration(
              registration: registration,
              reviewer: reviewer,
              role: result.role,
              reviewedIdentity: result.identity,
              reason: result.reason,
              directoryProject: reviewProject,
            );
            final dir = await _api.readDirectory(session.token);
            final remoteReg = await _api.getDocument(
              session.token,
              'campusRegistrations',
              registration.registrationId,
            );
            final publishedReg = approved.registration.copyWith(
              status: CampusRegistrationStatus.published,
              syncState: CampusSyncState.synced,
            );
            final bundle = TrustBundle.fromJsonString(approved.bundleJson);
            await _api.publishCampusRegistration(
              session.token,
              registration: publishedReg,
              version: bundle.bundleVersion,
              bundle: approved.bundleJson,
              directoryUpdateTime: dir?.updateTime,
              remoteRegistrationUpdateTime: remoteReg?.updateTime,
            );
            await registry.saveLastPublishedRoster(bundle, approved.bundleJson);
            await registry.saveRegistration(
              publishedReg,
              removePendingForRegistration: true,
            );
          }
          _clearDecisionId(registration.registrationId);
          await _refreshOnline();
          widget.onRegistryChanged?.call();
          _notify('Approval published');
          break;
        case _EditorAction.requestChanges:
        case _EditorAction.reject:
          final onlineApp = item.onlineApplication;
          if (onlineApp != null && _session != null) {
            final decisionId = _decisionIdFor(registration.registrationId);
            if (_publisher.isConfigured) {
              await _publisher.publishDecision(
                token: _session!.token,
                payload: {
                  'action': result.action == _EditorAction.requestChanges
                      ? 'request_changes'
                      : 'reject',
                  'decisionId': decisionId,
                  'accountUid': onlineApp.id,
                  'reason': result.reason,
                },
              );
            } else {
              await _api.decide(
                _session!.token,
                _session!.uid,
                onlineApp,
                result.action == _EditorAction.requestChanges
                    ? 'changes_requested'
                    : 'rejected',
                result.reason,
                decisionId: decisionId,
              );
            }
            _clearDecisionId(registration.registrationId);
            await _refreshOnline();
          } else if (registry != null) {
            final next = registration.copyWith(
              status: result.action == _EditorAction.requestChanges
                  ? CampusRegistrationStatus.changesRequested
                  : CampusRegistrationStatus.rejected,
              updatedAt: DateTime.now().toUtc(),
            );
            await registry.saveRegistration(next);
            await _loadLocalState();
          }
          widget.onRegistryChanged?.call();
          _notify('Decision recorded.');
          break;
        case _EditorAction.revoke:
          if (registry == null && !_publisher.isConfigured) return;
          if (registry != null && !_publisher.isConfigured) {
            final reviewer = await _ensureReviewerProfile();
            final dir = _session == null
                ? null
                : await _api.readDirectory(_session!.token);
            await registry.issueSignedCorrection(
              registration: registration,
              reviewer: reviewer,
              targetStatus: RegisteredDeviceStatus.revoked,
              role: result.role,
              remoteVersion: dir?.version ?? 0,
              directoryProject: reviewProject,
              reason: result.reason,
            );
            await _loadLocalState();
            widget.onRegistryChanged?.call();
            _notify('Registration revoked locally. Share or sync updated directory.');
          } else if (_session != null) {
            final decisionId = _decisionIdFor(registration.registrationId);
            final res = await _publisher.publishDecision(
              token: _session!.token,
              payload: {
                'action': 'sync_offline_decision',
                'decisionId': decisionId,
                'registrationId': registration.registrationId,
                if (registration.accountUid != null)
                  'accountUid': registration.accountUid,
                'role': result.role.name,
                'targetStatus': 'revoked',
                'overrideConflict': true,
                'reason': result.reason,
                'reviewedFields': result.identity.toFirestoreFields(),
                'registration': {
                  'registrationId': registration.registrationId,
                  'source': registration.source.name,
                  'status': 'revoked',
                  if (registration.accountUid != null)
                    'accountUid': registration.accountUid,
                  'deviceRegistration':
                      registration.activePhone.deviceRegistrationJson,
                  ...result.identity.toFirestoreFields(),
                },
              },
            );
            _clearDecisionId(registration.registrationId);
            if (registry != null && res.bundle != null) {
              await registry.saveLastPublishedRoster(
                TrustBundle.fromJsonString(res.bundle!),
                res.bundle!,
              );
              await registry.saveRegistration(
                registration.copyWith(
                  status: CampusRegistrationStatus.revoked,
                  syncState: CampusSyncState.synced,
                  updatedAt: DateTime.now().toUtc(),
                ),
                removePendingForRegistration: true,
              );
            }
            await _refreshOnline();
            widget.onRegistryChanged?.call();
            _notify('Approval published');
          }
          break;
        case _EditorAction.resolveConflict:
          if (registry == null) return;
          final reviewer = await _ensureReviewerProfile();
          final dir = _session == null
              ? null
              : await _api.readDirectory(_session!.token);
          await registry.issueSignedCorrection(
            registration: registration,
            reviewer: reviewer,
            targetStatus: RegisteredDeviceStatus.approved,
            role: result.role,
            remoteVersion: dir?.version ?? 0,
            directoryProject: reviewProject,
            reason: result.reason,
          );
          await _loadLocalState();
          widget.onRegistryChanged?.call();
          _notify('Signed conflict correction created.');
          break;
        case _EditorAction.approveLink:
          final session = _session!;
          final link = item.linkRequest!;
          if (_publisher.isConfigured) {
            final decisionId = _decisionIdFor(registration.registrationId);
            final res = await _publisher.publishDecision(
              token: session.token,
              payload: {
                'action': 'approve_link',
                'decisionId': decisionId,
                'registrationId': registration.registrationId,
                'accountUid': link.id,
                'role': result.role.name,
                'reviewedFields': result.identity.toFirestoreFields(),
              },
            );
            _clearDecisionId(registration.registrationId);
            if (registry != null) {
              if (res.bundle != null && res.bundle!.trim().isNotEmpty) {
                await registry.saveLastPublishedRoster(
                  TrustBundle.fromJsonString(res.bundle!),
                  res.bundle!,
                );
              }
              await registry.saveRegistration(
                registration.copyWith(
                  accountUid: link.id,
                  status: CampusRegistrationStatus.published,
                  syncState: CampusSyncState.synced,
                  updatedAt: DateTime.now().toUtc(),
                ),
                removePendingForRegistration: true,
              );
            }
            await _refreshOnline();
            widget.onRegistryChanged?.call();
            _notify('Approval published');
            break;
          }
          if (registry == null) return;
          final proof = AccountLinkProof.fromMap(link.fields);
          await proof.verify(
            expectedRegistrationId: registration.registrationId,
            expectedAccountUid: link.id,
            expectedDeviceId: registration.activePhone.deviceId,
            expectedPublicKey: registration.activePhone.publicKey ?? '',
            expectedSigningPublicKey:
                registration.activePhone.signingPublicKey ?? '',
            expectedKeyVersion: registration.activePhone.keyVersion,
            expectedProject: reviewProject.isEmpty ? null : reviewProject,
          );
          final existingApp = await _api.get(session.token, link.id);
          final dir = await _api.readDirectory(session.token);
          final devices = await registry.loadDevices();
          final bundleJson = await registry.buildTrustBundleJson(
            devices,
            directoryProject: reviewProject,
            minimumPreviousVersion: dir?.version ?? 0,
          );
          final parsed = TrustBundle.fromJsonString(bundleJson);
          final linkedReg = registration.copyWith(
            accountUid: link.id,
            status: CampusRegistrationStatus.published,
            syncState: CampusSyncState.synced,
            updatedAt: DateTime.now().toUtc(),
          );
          final remoteReg = await _api.getDocument(
            session.token,
            'campusRegistrations',
            registration.registrationId,
          );
          await _api.completeAccountLink(
            session.token,
            reviewerUid: session.uid,
            registration: linkedReg,
            linkRequest: link,
            existingApplication: existingApp,
            version: parsed.bundleVersion,
            bundle: bundleJson,
            directoryUpdateTime: dir?.updateTime,
            remoteRegistrationUpdateTime: remoteReg?.updateTime,
          );
          await registry.saveLastPublishedRoster(parsed, bundleJson);
          await registry.saveRegistration(
            linkedReg,
            removePendingForRegistration: true,
          );
          await _refreshOnline();
          widget.onRegistryChanged?.call();
          _notify('Phone registration linked to Firebase account.');
          break;
        case _EditorAction.approveReplacementOrRecovery:
          if (_publisher.isConfigured && _session != null) {
            final decisionId = _decisionIdFor(registration.registrationId);
            final isRecovery = item.recoveryRequest != null;
            final accUid = isRecovery
                ? item.recoveryRequest!.id
                : (item.onlineApplication?.id ?? registration.accountUid);
            final res = await _publisher.publishDecision(
              token: _session!.token,
              payload: {
                'action': isRecovery ? 'approve_recovery' : 'approve_replacement',
                'decisionId': decisionId,
                'registrationId': registration.registrationId,
                'accountUid': ?accUid,
                'role': result.role.name,
                'reason': result.reason,
                if (isRecovery)
                  'verificationMethod':
                      result.verificationMethod ?? 'desk_id_check',
                if (item.pendingNewPhone?.deviceRegistrationJson != null)
                  'deviceRegistration':
                      item.pendingNewPhone!.deviceRegistrationJson,
                'reviewedFields': result.identity.toFirestoreFields(),
              },
            );
            _clearDecisionId(registration.registrationId);
            if (registry != null && item.pendingNewPhone != null) {
              if (res.bundle != null && res.bundle!.trim().isNotEmpty) {
                await registry.saveLastPublishedRoster(
                  TrustBundle.fromJsonString(res.bundle!),
                  res.bundle!,
                );
              }
              await registry.saveRegistration(
                registration.copyWith(
                  accountUid: accUid,
                  activePhone: item.pendingNewPhone!,
                  status: CampusRegistrationStatus.published,
                  syncState: CampusSyncState.synced,
                  updatedAt: DateTime.now().toUtc(),
                ),
                removePendingForRegistration: true,
              );
            }
            await _refreshOnline();
            widget.onRegistryChanged?.call();
            _notify('Approval published');
            break;
          }
          if (registry == null) return;
          final reviewer = await _ensureReviewerProfile();
          final newPhone = item.pendingNewPhone!;
          final dir = _session == null
              ? null
              : await _api.readDirectory(_session!.token);
          final staged = await registry.stagePhoneReplacement(
            registration: registration,
            newPhone: newPhone,
            reviewer: reviewer,
            directoryProject: reviewProject,
            previousVersion: dir?.version ?? 0,
            publishedBundle: dir == null
                ? null
                : TrustBundle.fromJsonString(dir.bundle),
            reason: result.reason,
          );
          if (_session != null && item.recoveryRequest != null) {
            final parsed = TrustBundle.fromJsonString(staged.bundleJson);
            final remoteReg = await _api.getDocument(
              _session!.token,
              'campusRegistrations',
              registration.registrationId,
            );
            final existingApp = await _api.get(
              _session!.token,
              item.recoveryRequest!.id,
            );
            await _api.approveRecoveryAndPublish(
              _session!.token,
              reviewerUid: _session!.uid,
              verificationMethod: result.verificationMethod ?? 'desk_id_check',
              registration: staged.registration.copyWith(
                accountUid: item.recoveryRequest!.id,
                status: CampusRegistrationStatus.published,
                syncState: CampusSyncState.synced,
              ),
              recoveryRequest: item.recoveryRequest!,
              existingApplication: existingApp,
              newDeviceRegistrationJson:
                  newPhone.deviceRegistrationJson ?? '',
              version: parsed.bundleVersion,
              bundle: staged.bundleJson,
              directoryUpdateTime: dir?.updateTime,
              remoteRegistrationUpdateTime: remoteReg?.updateTime,
            );
            await registry.saveLastPublishedRoster(parsed, staged.bundleJson);
          } else if (_session != null && item.onlineApplication != null) {
            final parsed = TrustBundle.fromJsonString(staged.bundleJson);
            final remoteReg = await _api.getDocument(
              _session!.token,
              'campusRegistrations',
              registration.registrationId,
            );
            await _api.publishPhoneReplacement(
              _session!.token,
              application: item.onlineApplication!,
              registration: staged.registration.copyWith(
                status: CampusRegistrationStatus.published,
                syncState: CampusSyncState.synced,
              ),
              newDeviceRegistrationJson:
                  newPhone.deviceRegistrationJson ?? '',
              version: parsed.bundleVersion,
              bundle: staged.bundleJson,
              directoryUpdateTime: dir?.updateTime,
              remoteRegistrationUpdateTime: remoteReg?.updateTime,
            );
            await registry.saveLastPublishedRoster(parsed, staged.bundleJson);
          }
          await _loadLocalState();
          if (_session != null) await _refreshOnline();
          widget.onRegistryChanged?.call();
          _notify('Replacement approved. Previous phone keys retired.');
          break;
      }
    });
    if (approvalQr != null && mounted) {
      await showApprovalQrDialog(
        context,
        title: approvalQr!.title,
        payloadJson: approvalQr!.packageJson,
        copyJson: approvalQr!.packageJson,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_loadError!),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _loadLocalState,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final items = _buildUnifiedQueue();
    final waitingSyncCount = _pendingSync.length;
    final availableRoles = {
      ...RegisteredDeviceRole.campusRoles,
      for (final r in _localRegistrations) r.role,
    }.toList();

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AdminTheme.pageWidth),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  MediaQuery.sizeOf(context).width < 600 ? 14 : 24,
                  20,
                  MediaQuery.sizeOf(context).width < 600 ? 14 : 24,
                  36,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: const Text(
                        'Registrations',
                        style: AdminTheme.pageTitle,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Review online campus requests and phone QR registrations in one place.',
                      style: TextStyle(color: AdminTheme.muted),
                    ),
                    const SizedBox(height: 16),
                    _buildReviewerSessionCard(waitingSyncCount),
                    if (_hasLocalRegistry) ...[
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          if (widget.onScanPhoneQr != null)
                            FilledButton.icon(
                              key: const ValueKey('unified-scan-qr-button'),
                              onPressed: _busy
                                  ? null
                                  : () => _scanOrPastePhoneQr(paste: false),
                              icon: const Icon(Icons.qr_code_scanner_rounded),
                              label: const Text('Scan phone QR'),
                            ),
                          OutlinedButton.icon(
                            key: const ValueKey('unified-paste-qr-button'),
                            onPressed: _busy
                                ? null
                                : () => _scanOrPastePhoneQr(paste: true),
                            icon: const Icon(Icons.content_paste_outlined),
                            label: const Text('Paste phone QR JSON'),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('unified-show-approval-qr'),
                            onPressed: _busy ? null : _showDirectoryQr,
                            icon: const Icon(Icons.qr_code_2_rounded),
                            label: const Text('Show QR for Phone Scan'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _copyTrustBundle,
                            icon: const Icon(Icons.content_copy_rounded),
                            label: const Text('Copy Trust Bundle JSON'),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 18),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final search = TextField(
                          key: const ValueKey('unified-registration-search'),
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: 'Search registrations',
                            hintText: 'Name, school ID, email, or device ID',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _search.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Clear search',
                                    onPressed: () => setState(_search.clear),
                                    icon: const Icon(Icons.close),
                                  ),
                          ),
                        );
                        final role = DropdownButtonFormField<String>(
                          key: ValueKey(_roleFilter),
                          initialValue: _roleFilter,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Filter by role',
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: 'all',
                              child: Text('All roles'),
                            ),
                            for (final r in availableRoles)
                              DropdownMenuItem(
                                value: r.name,
                                child: Text(r.label),
                              ),
                          ],
                          onChanged: (v) =>
                              setState(() => _roleFilter = v ?? 'all'),
                        );
                        if (constraints.maxWidth >= 560) {
                          return Row(
                            children: [
                              Expanded(flex: 3, child: search),
                              const SizedBox(width: 12),
                              Expanded(flex: 2, child: role),
                            ],
                          );
                        }
                        return Column(
                          children: [search, const SizedBox(height: 12), role],
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final entry in const [
                          ('all', 'All'),
                          ('needs_review', 'Needs review'),
                          ('waiting_sync', 'Approved · waiting to sync'),
                          ('published', 'Published'),
                          ('changes_requested', 'Changes requested'),
                          ('rejected', 'Rejected'),
                          ('revoked', 'Revoked'),
                          ('conflicts', 'Conflicts'),
                        ])
                          FilterChip(
                            label: Text(entry.$2),
                            selected: _statusFilter == entry.$1,
                            onSelected: (_) =>
                                setState(() => _statusFilter = entry.$1),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Showing ${items.length} registrations',
                      style: const TextStyle(color: AdminTheme.muted),
                    ),
                    const SizedBox(height: 12),
                    if (_busy) const LinearProgressIndicator(),
                    if (items.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: Text(
                            'No registrations match these filters. Scan a phone QR or check online requests.',
                          ),
                        ),
                      )
                    else
                      for (final item in items)
                        _UnifiedQueueCard(
                          item: item,
                          onOpen: _busy ? null : () => _openUnifiedEditor(item),
                        ),
                    if (widget.validationPanel != null) ...[
                      const SizedBox(height: 20),
                      widget.validationPanel!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReviewerSessionCard(int waitingSyncCount) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_session == null) ...[
              Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 240,
                    child: TextField(
                      controller: _email,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: 'Reviewer email',
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 200,
                    child: TextField(
                      controller: _password,
                      enabled: !_busy,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Password'),
                    ),
                  ),
                  FilledButton(
                    onPressed: _busy ? null : _signInReviewer,
                    child: Text(
                      _hasLocalRegistry ? 'Sign in for online sync' : 'Sign in',
                    ),
                  ),
                ],
              ),
              if (waitingSyncCount > 0) ...[
                const SizedBox(height: 10),
                Text(
                  '$waitingSyncCount offline approval(s) saved locally · waiting to sync when signed in online.',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ] else
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Signed in as ${_session!.email}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _runBusy(
                            () => _refreshOnline(reconcile: _hasLocalRegistry),
                          ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Refresh'),
                  ),
                  if (waitingSyncCount > 0)
                    FilledButton.icon(
                      onPressed: _busy ? null : _syncPendingDecisions,
                      icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                      label: Text('Sync $waitingSyncCount pending'),
                    ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _session = null;
                            _onlineApplications = [];
                            _remoteRegistrations = [];
                            _linkRequests = [];
                            _recoveryRequests = [];
                          }),
                    child: const Text('Sign out'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _UnifiedQueueItem {
  const _UnifiedQueueItem({
    required this.registration,
    this.onlineApplication,
    this.linkRequest,
    this.recoveryRequest,
    this.pendingNewPhone,
  });

  final CampusRegistration registration;
  final ReviewApplication? onlineApplication;
  final ReviewApplication? linkRequest;
  final ReviewApplication? recoveryRequest;
  final RegistrationPhoneBinding? pendingNewPhone;

  _UnifiedQueueItem copyWith({
    CampusRegistration? registration,
    ReviewApplication? onlineApplication,
    ReviewApplication? linkRequest,
    ReviewApplication? recoveryRequest,
    RegistrationPhoneBinding? pendingNewPhone,
  }) => _UnifiedQueueItem(
    registration: registration ?? this.registration,
    onlineApplication: onlineApplication ?? this.onlineApplication,
    linkRequest: linkRequest ?? this.linkRequest,
    recoveryRequest: recoveryRequest ?? this.recoveryRequest,
    pendingNewPhone: pendingNewPhone ?? this.pendingNewPhone,
  );
}

class _UnifiedQueueCard extends StatelessWidget {
  const _UnifiedQueueCard({required this.item, required this.onOpen});

  final _UnifiedQueueItem item;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final reg = item.registration;
    final syncLabel = reg.syncState == CampusSyncState.waitingToSync
        ? 'Approved on this PC · waiting to sync'
        : reg.status.label;
    final sourceText = reg.isLinked && reg.source == CampusRegistrationSource.qr
        ? 'Linked'
        : reg.source.label;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          onTap: onOpen,
          title: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                reg.identity.displayName.isEmpty
                    ? reg.activePhone.deviceId
                    : reg.identity.displayName,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Chip(label: Text(sourceText)),
              Chip(label: Text(reg.role.label)),
              Chip(label: Text(syncLabel)),
              if (item.linkRequest != null)
                const Chip(label: Text('Account link request')),
              if (item.recoveryRequest != null)
                const Chip(label: Text('Lost phone recovery')),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (reg.identity.summarySubtitle.isNotEmpty)
                Text(reg.identity.summarySubtitle),
              Text('Phone: ${reg.activePhone.deviceId} · Reg: ${reg.registrationId}'),
              if (reg.conflictReason != null)
                Text(
                  reg.conflictReason!,
                  style: const TextStyle(color: AdminTheme.action),
                ),
            ],
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      ),
    );
  }
}

enum _EditorAction {
  approveOffline,
  approveAndPublishOnline,
  requestChanges,
  reject,
  revoke,
  resolveConflict,
  approveLink,
  approveReplacementOrRecovery,
}

class _EditorOutcome {
  const _EditorOutcome({
    required this.action,
    required this.identity,
    required this.role,
    this.reason = '',
    this.verificationMethod,
  });

  final _EditorAction action;
  final CampusIdentityFields identity;
  final RegisteredDeviceRole role;
  final String reason;
  final String? verificationMethod;
}

class _UnifiedRegistrationEditorDialog extends StatefulWidget {
  const _UnifiedRegistrationEditorDialog({
    required this.item,
    required this.hasOnlineSession,
    required this.hasLocalRegistry,
    required this.sessionUid,
  });

  final _UnifiedQueueItem item;
  final bool hasOnlineSession;
  final bool hasLocalRegistry;
  final String? sessionUid;

  @override
  State<_UnifiedRegistrationEditorDialog> createState() =>
      _UnifiedRegistrationEditorDialogState();
}

class _UnifiedRegistrationEditorDialogState
    extends State<_UnifiedRegistrationEditorDialog> {
  late CampusAffiliation _affiliation =
      widget.item.registration.identity.affiliation;
  late RegisteredDeviceRole _role = widget.item.registration.role;
  late final TextEditingController _name = TextEditingController(
    text: widget.item.registration.identity.displayName,
  );
  late final TextEditingController _studentNo = TextEditingController(
    text: widget.item.registration.identity.studentNumber,
  );
  late final TextEditingController _course = TextEditingController(
    text: widget.item.registration.identity.course,
  );
  late final TextEditingController _year = TextEditingController(
    text: widget.item.registration.identity.yearLevel,
  );
  late final TextEditingController _set = TextEditingController(
    text: widget.item.registration.identity.sectionSet,
  );
  late final TextEditingController _employeeId = TextEditingController(
    text: widget.item.registration.identity.employeeId,
  );
  late final TextEditingController _unit = TextEditingController(
    text: widget.item.registration.identity.unit,
  );
  late final TextEditingController _phone = TextEditingController(
    text: widget.item.registration.identity.phone,
  );
  late final TextEditingController _address = TextEditingController(
    text: widget.item.registration.identity.address,
  );
  final TextEditingController _reason = TextEditingController();
  String _verificationMethod = 'desk_id_check';
  String? _validationError;

  @override
  void dispose() {
    _name.dispose();
    _studentNo.dispose();
    _course.dispose();
    _year.dispose();
    _set.dispose();
    _employeeId.dispose();
    _unit.dispose();
    _phone.dispose();
    _address.dispose();
    _reason.dispose();
    super.dispose();
  }

  CampusIdentityFields _collectIdentity() => CampusIdentityFields(
    affiliation: _affiliation,
    displayName: _name.text.trim(),
    studentNumber: _studentNo.text.trim(),
    course: _course.text.trim(),
    yearLevel: _year.text.trim(),
    sectionSet: _set.text.trim(),
    employeeId: _employeeId.text.trim(),
    unit: _unit.text.trim(),
    phone: _phone.text.trim(),
    address: _address.text.trim(),
  );

  void _submit(_EditorAction action) {
    final identity = _collectIdentity();
    if (action == _EditorAction.approveOffline ||
        action == _EditorAction.approveAndPublishOnline) {
      final errors = identity.validateRequired();
      if (errors.isNotEmpty) {
        setState(() => _validationError = errors.values.first);
        return;
      }
    }
    if ((action == _EditorAction.requestChanges ||
            action == _EditorAction.reject) &&
        _reason.text.trim().isEmpty) {
      setState(() => _validationError = 'Enter a reason for the applicant.');
      return;
    }
    Navigator.of(context).pop(
      _EditorOutcome(
        action: action,
        identity: identity,
        role: _role,
        reason: _reason.text.trim(),
        verificationMethod: _verificationMethod,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reg = widget.item.registration;
    final selfBlocked =
        widget.sessionUid != null &&
        reg.accountUid != null &&
        widget.sessionUid == reg.accountUid;
    final availableRoles = {
      ...RegisteredDeviceRole.campusRoles,
      reg.role,
    }.toList();
    final replacementPending =
        widget.item.pendingNewPhone != null ||
        widget.item.recoveryRequest != null;
    return AlertDialog(
      title: Text(
        reg.identity.displayName.isEmpty
            ? 'Review phone registration'
            : 'Review ${reg.identity.displayName}',
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Registration ID: ${reg.registrationId}'),
              Text('Source: ${reg.source.label} · Status: ${reg.status.label}'),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F6F7),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AdminTheme.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Verified phone keys (read-only)',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    SelectableText('Device ID: ${reg.activePhone.deviceId}'),
                    Text('Key version: v${reg.activePhone.keyVersion}'),
                    if (reg.activePhone.publicKey != null)
                      Text('Encryption key: ${reg.activePhone.publicKey}'),
                    if (reg.activePhone.signingPublicKey != null)
                      Text('Signing key: ${reg.activePhone.signingPublicKey}'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
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
                controller: _name,
                decoration: const InputDecoration(labelText: 'Full name'),
              ),
              const SizedBox(height: 10),
              if (_affiliation == CampusAffiliation.student) ...[
                TextField(
                  controller: _studentNo,
                  decoration: const InputDecoration(labelText: 'Student number'),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _course,
                        decoration: const InputDecoration(labelText: 'Course'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _year,
                        decoration: const InputDecoration(labelText: 'Year'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _set,
                        decoration: const InputDecoration(labelText: 'Set'),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                TextField(
                  controller: _employeeId,
                  decoration: const InputDecoration(labelText: 'Employee ID'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _unit,
                  decoration: const InputDecoration(labelText: 'Unit / Office'),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone number (optional)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _address,
                      decoration: const InputDecoration(
                        labelText: 'Address (optional)',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<RegisteredDeviceRole>(
                initialValue: _role,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Phone access role'),
                items: [
                  for (final role in availableRoles)
                    DropdownMenuItem(value: role, child: Text(role.label)),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _role = value);
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _reason,
                decoration: const InputDecoration(
                  labelText: 'Review note / reason',
                ),
              ),
              if (widget.item.recoveryRequest != null) ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: _verificationMethod,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Recovery verification method',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'desk_id_check',
                      child: Text('Desk ID check'),
                    ),
                    DropdownMenuItem(
                      value: 'campus_email_match',
                      child: Text('Verified campus email match'),
                    ),
                    DropdownMenuItem(
                      value: 'mailbox_code',
                      child: Text('Campus mailbox single-use code'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _verificationMethod = v);
                  },
                ),
              ],
              if (_validationError != null) ...[
                const SizedBox(height: 10),
                Text(
                  _validationError!,
                  style: const TextStyle(color: AdminTheme.action),
                ),
              ],
              if (selfBlocked) ...[
                const SizedBox(height: 10),
                const Text(
                  'Another reviewer must approve or change your own account.',
                  style: TextStyle(color: AdminTheme.action),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (widget.item.linkRequest != null && widget.hasOnlineSession)
          FilledButton(
            onPressed: selfBlocked
                ? null
                : () => _submit(_EditorAction.approveLink),
            child: const Text('Verify & link account'),
          ),
        if (replacementPending)
          FilledButton(
            onPressed: selfBlocked
                ? null
                : () => _submit(_EditorAction.approveReplacementOrRecovery),
            child: const Text('Approve replacement'),
          ),
        if (reg.status == CampusRegistrationStatus.conflict &&
            widget.hasLocalRegistry)
          FilledButton(
            onPressed: selfBlocked
                ? null
                : () => _submit(_EditorAction.resolveConflict),
            child: const Text('Issue signed correction'),
          ),
        if (widget.item.onlineApplication != null ||
            reg.source == CampusRegistrationSource.online) ...[
          OutlinedButton(
            onPressed: selfBlocked
                ? null
                : () => _submit(_EditorAction.requestChanges),
            child: const Text('Request correction'),
          ),
          TextButton(
            onPressed: selfBlocked
                ? null
                : () => _submit(_EditorAction.reject),
            child: const Text('Reject'),
          ),
        ],
        if (reg.status == CampusRegistrationStatus.published ||
            reg.status == CampusRegistrationStatus.approvedLocal)
          TextButton(
            onPressed: selfBlocked
                ? null
                : () => _submit(_EditorAction.revoke),
            child: const Text('Revoke'),
          ),
        if (widget.hasLocalRegistry)
          OutlinedButton(
            onPressed: selfBlocked
                ? null
                : () => _submit(_EditorAction.approveOffline),
            child: const Text('Approve offline & show QR'),
          ),
        if (widget.hasOnlineSession)
          FilledButton(
            onPressed: selfBlocked
                ? null
                : () => _submit(_EditorAction.approveAndPublishOnline),
            child: const Text('Approve & publish'),
          ),
      ],
    );
  }
}
