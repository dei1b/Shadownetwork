import 'package:flutter/material.dart';
import 'package:shadownetwork/core/constants/mobile_ui_tokens.dart';
import 'package:shadownetwork/core/widgets/action_feedback.dart';
import 'package:shadownetwork/core/widgets/mobile_ui_components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../messaging/domain/entities/peer.dart';
import '../../../messaging/presentation/providers/local_messaging_providers.dart';
import '../../../messaging/presentation/providers/peer_location_providers.dart';
import '../../../security/domain/entities/device_crypto_identity.dart';
import '../../../security/domain/entities/device_registration_qr.dart';
import '../../data/services/trust_bundle_store.dart';
import '../../domain/entities/device_access_profile.dart';
import '../../domain/entities/trust_bundle.dart';
import '../providers/device_access_provider.dart';

class TrustBundleImportPage extends ConsumerStatefulWidget {
  const TrustBundleImportPage({super.key});

  @override
  ConsumerState<TrustBundleImportPage> createState() =>
      _TrustBundleImportPageState();
}

class _TrustBundleImportPageState extends ConsumerState<TrustBundleImportPage> {
  TrustBundleStore get _store => ref.read(trustBundleStoreProvider);
  final TextEditingController _jsonController = TextEditingController();

  TrustBundle? _bundle;
  bool _isLoading = true;
  bool _isImporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBundle();
  }

  @override
  void dispose() {
    _jsonController.dispose();
    super.dispose();
  }

  Future<void> _loadBundle() async {
    try {
      final bundle = await _store.loadBundle();
      if (!mounted) {
        return;
      }
      setState(() {
        _bundle = bundle;
        _isLoading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _error = 'Unable to load the saved approval update.';
      });
    }
  }

  Future<void> _scanQr() async {
    final rawBundle = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _TrustBundleScannerPage()),
    );
    if (rawBundle == null || rawBundle.trim().isEmpty) {
      return;
    }
    await _importBundle(rawBundle);
  }

  Future<void> _importFromClipboard() async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text;
    if (text == null || text.trim().isEmpty) {
      _showSnackBar(
        'No approval code found on the clipboard.',
        kind: FeedbackKind.warning,
      );
      return;
    }
    await _importBundle(text);
  }

  Future<void> _importFromTextField() async {
    await _importBundle(_jsonController.text);
  }

  Future<void> _copyDeviceId(String deviceId) async {
    await ActionFeedback.copy(context, deviceId, message: 'Device ID copied.');
  }

  Future<void> _copyPublicKey(String publicKey) async {
    await ActionFeedback.copy(
      context,
      publicKey,
      message: 'X25519 public key copied.',
    );
  }

  Future<void> _showDeviceRegistrationQr(
    Peer peer,
    DeviceCryptoIdentity identity,
  ) async {
    final DeviceRegistrationQr registration;
    try {
      final signingIdentity = await ref.read(
        deviceSigningIdentityProvider.future,
      );
      registration = await DeviceRegistrationQr.createSigned(
        deviceId: peer.id,
        identity: identity,
        signingIdentity: signingIdentity,
      );
    } catch (_) {
      if (mounted) {
        _showSnackBar(
          'Could not prepare the registration code. Try again.',
          kind: FeedbackKind.error,
        );
      }
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) =>
          _DeviceRegistrationQrDialog(registration: registration),
    );
  }

  Future<void> _importBundle(String source) async {
    if (!mounted || _isImporting) {
      return;
    }
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() {
      _isImporting = true;
      _error = null;
    });

    try {
      final candidate = TrustBundle.fromJsonString(source.trim());
      if (!await _store.hasPinnedIssuer()) {
        if (!mounted) {
          return;
        }
        final trusted = await _confirmFirstAdmin(candidate);
        if (trusted != true) {
          return;
        }
      }
      final bundle = await _store.importBundleJson(source.trim());
      container.invalidate(deviceAccessProfileProvider);
      if (!mounted) {
        return;
      }
      setState(() {
        _bundle = bundle;
        _jsonController.clear();
      });
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.message);
      _showSnackBar(
        'Could not save the approval update. Ask the campus administrator for a current code.',
        kind: FeedbackKind.error,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(
        () => _error =
            'Could not save the approval update. Try scanning the code again.',
      );
      _showSnackBar(
        'Could not save the approval update. Check the code and try again.',
        kind: FeedbackKind.error,
      );
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  Future<bool?> _confirmFirstAdmin(TrustBundle bundle) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: MobileUiTokens.canvas,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(MobileUiTokens.cardRadius),
          ),
          title: const Text(
            'Is this your campus administrator?',
            style: MobileUiTokens.sectionHeading,
          ),
          content: Text(
            'Only continue if your campus administrator gave you this code. This phone will accept future approval updates from the same admin.\n\nAdmin ID: ${bundle.issuer?.signingKeyId ?? 'unavailable'}',
            style: MobileUiTokens.body.copyWith(fontSize: 14),
          ),
          actions: [
            TextButton(
              style: MobileButtonStyles.redText,
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: MobileButtonStyles.primaryFilled,
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Trust administrator'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _clearBundle() async {
    if (_isImporting) return;
    try {
      await _store.clearBundle();
      final repository = await ref.read(trustRepositoryProvider.future);
      await repository.clear();
      if (!mounted) {
        return;
      }
      ref.invalidate(sharedPeerLocationsProvider);
      setState(() => _bundle = null);
      ref.invalidate(deviceAccessProfileProvider);
      _showSnackBar('Approval update removed from this phone.');
    } catch (_) {
      _showSnackBar(
        'Could not remove the approval update. Reopen this screen to check its status.',
        kind: FeedbackKind.error,
      );
    }
  }

  void _showSnackBar(
    String message, {
    FeedbackKind kind = FeedbackKind.success,
  }) {
    ActionFeedback.show(context, message, kind: kind);
  }

  Widget _buildApprovalOutcome(AsyncValue<DeviceAccessProfile> access) {
    return access.when(
      skipLoadingOnRefresh: false,
      data: (profile) => switch (profile.level) {
        DeviceAccessLevel.unregistered => const ActionStatus(
          title: 'This phone is still unregistered',
          message:
              'Show your registration code to the campus administrator and ask them to approve this phone.',
          kind: FeedbackKind.warning,
        ),
        DeviceAccessLevel.revoked => const ActionStatus(
          title: 'Approval was removed',
          message:
              'Contact the campus administrator to check this phone’s registration.',
          kind: FeedbackKind.warning,
        ),
        DeviceAccessLevel.keyMismatch => const ActionStatus(
          title: 'Register this phone again',
          message:
              'Show your current registration code to the campus administrator and ask for a new approval code.',
          kind: FeedbackKind.warning,
        ),
        DeviceAccessLevel.outdatedBundle => const ActionStatus(
          title: 'Approval code expired',
          message: 'Ask the campus administrator for a current approval code.',
          kind: FeedbackKind.warning,
        ),
        _ => ActionStatus(
          title: 'This phone is approved',
          message: profile.canAccessResponderInterface
              ? 'Responder tools are ready to use.'
              : 'This phone is now registered with DNSC.',
          kind: FeedbackKind.success,
        ),
      },
      loading: () => const ActionStatus(
        title: 'Checking this phone',
        message: 'Checking whether the approval code covers this phone.',
      ),
      error: (_, _) => const ActionStatus(
        title: 'Couldn’t check this phone’s approval',
        message:
            'The approval code was saved. Scan it again to retry the check.',
        kind: FeedbackKind.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localPeer = ref.watch(localPeerProvider);
    final cryptoIdentity = ref.watch(deviceCryptoIdentityProvider);
    final approval = _bundle == null || _isImporting
        ? null
        : ref.watch(deviceAccessProfileProvider);

    return Scaffold(
      backgroundColor: MobileUiTokens.canvas,
      appBar: buildMobileAppBar(title: 'Backup registration'),
      body: SafeArea(
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  color: MobileUiTokens.brandRed,
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _TrustHeader(bundle: _bundle),
                    const SizedBox(height: 16),
                    _DeviceIdentityCard(
                      localPeer: localPeer,
                      cryptoIdentity: cryptoIdentity,
                      onCopyDeviceId: _copyDeviceId,
                      onCopyPublicKey: _copyPublicKey,
                      onShowRegistrationQr: _showDeviceRegistrationQr,
                    ),
                    const SizedBox(height: 16),
                    _TrustPanel(
                      stepLabel: 'Step 2',
                      title: "2. Scan the admin's approval code",
                      subtitle:
                          'After registration, scan the code the campus administrator gives you. Use this step again when they give you an updated code.',
                      child: Column(
                        children: [
                          if (approval != null) ...[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(
                                MobileUiTokens.controlRadius,
                              ),
                              child: _buildApprovalOutcome(approval),
                            ),
                            const SizedBox(height: 12),
                          ],
                          _ImportActions(
                            isImporting: _isImporting,
                            onScanQr: _scanQr,
                            onImportClipboard: _importFromClipboard,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    MobileSectionCard(
                      padding: EdgeInsets.zero,
                      child: Theme(
                        data: Theme.of(context).copyWith(
                          dividerColor: Colors.transparent,
                          splashColor: MobileUiTokens.redTint.withValues(
                            alpha: 0.4,
                          ),
                        ),
                        child: ExpansionTile(
                          shape: const Border(),
                          collapsedShape: const Border(),
                          tilePadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          iconColor: MobileUiTokens.brandRed,
                          collapsedIconColor: MobileUiTokens.mutedInk,
                          title: const Text(
                            'Other ways to enter a code',
                            style: MobileUiTokens.bodyStrong,
                          ),
                          subtitle: const Text(
                            'Paste approval text manually',
                            style: MobileUiTokens.subtitle,
                          ),
                          children: [
                            const MobileTileDivider(),
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: _ManualImportCard(
                                controller: _jsonController,
                                isImporting: _isImporting,
                                onImport: _importFromTextField,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      _ErrorCard(message: _error!),
                    ],
                    const SizedBox(height: 16),
                    _BundleSummaryCard(
                      bundle: _bundle,
                      onClear: _isImporting ? null : _clearBundle,
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _TrustBundleScannerPage extends StatefulWidget {
  const _TrustBundleScannerPage();

  @override
  State<_TrustBundleScannerPage> createState() =>
      _TrustBundleScannerPageState();
}

class _TrustBundleScannerPageState extends State<_TrustBundleScannerPage> {
  bool _handledCode = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan approval code'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_handledCode) {
                return;
              }
              final rawValue = capture.barcodes
                  .map((barcode) => barcode.rawValue)
                  .whereType<String>()
                  .firstOrNull;
              if (rawValue == null || rawValue.trim().isEmpty) {
                return;
              }
              _handledCode = true;
              Navigator.of(context).pop(rawValue);
            },
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          const Positioned(
            left: 24,
            right: 24,
            bottom: 32,
            child: Text(
              'Point the phone at the QR shown on the PC admin dashboard.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrustHeader extends StatelessWidget {
  const _TrustHeader({required this.bundle});

  final TrustBundle? bundle;

  @override
  Widget build(BuildContext context) {
    final saved = bundle;
    return MobileStatusBanner(
      tone: saved == null ? MobileStatusTone.info : MobileStatusTone.positive,
      icon: saved == null
          ? Icons.qr_code_2_rounded
          : Icons.verified_user_outlined,
      message: saved == null
          ? 'The campus administrator registers your phone and gives you an approval code. You can still send an SOS before registering.'
          : 'An approval update from the campus administrator is saved on this phone.',
    );
  }
}

class _DeviceIdentityCard extends ConsumerWidget {
  const _DeviceIdentityCard({
    required this.localPeer,
    required this.cryptoIdentity,
    required this.onCopyDeviceId,
    required this.onCopyPublicKey,
    required this.onShowRegistrationQr,
  });

  final AsyncValue<Peer> localPeer;
  final AsyncValue<DeviceCryptoIdentity> cryptoIdentity;
  final ValueChanged<String> onCopyDeviceId;
  final ValueChanged<String> onCopyPublicKey;
  final void Function(Peer, DeviceCryptoIdentity) onShowRegistrationQr;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _TrustPanel(
      stepLabel: 'Step 1',
      title: '1. Show your registration code',
      subtitle: 'Show this code to the campus administrator.',
      child: localPeer.when(
        data: (peer) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cryptoIdentity.when(
              data: (identity) => SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => onShowRegistrationQr(peer, identity),
                  style: MobileButtonStyles.primaryFilled,
                  icon: const Icon(Icons.qr_code_2_rounded),
                  label: const Text('Show my registration code'),
                ),
              ),
              loading: () => const LinearProgressIndicator(
                color: MobileUiTokens.brandRed,
                backgroundColor: MobileUiTokens.redTint,
              ),
              error: (_, _) => const Text(
                'Unable to prepare your code. Reopen this screen to try again.',
                style: MobileUiTokens.subtitle,
              ),
            ),
            const SizedBox(height: 6),
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                shape: const Border(),
                collapsedShape: const Border(),
                tilePadding: EdgeInsets.zero,
                iconColor: MobileUiTokens.brandRed,
                collapsedIconColor: MobileUiTokens.mutedInk,
                title: const Text(
                  'Technical details',
                  style: MobileUiTokens.bodyStrong,
                ),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: MobileUiTokens.warmSurface,
                      borderRadius: BorderRadius.circular(
                        MobileUiTokens.controlRadius,
                      ),
                      border: Border.all(color: MobileUiTokens.border),
                    ),
                    child: SelectableText(
                      peer.id,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        color: MobileUiTokens.deepRed,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Name: ${peer.name}',
                          style: MobileUiTokens.subtitle,
                        ),
                      ),
                      TextButton.icon(
                        style: MobileButtonStyles.redText,
                        onPressed: () => onCopyDeviceId(peer.id),
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('Copy'),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: MobileTileDivider(),
                  ),
                  const Text(
                    'Encryption public key',
                    style: TextStyle(
                      fontFamily: MobileUiTokens.fontFamily,
                      color: MobileUiTokens.deepRed,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  cryptoIdentity.when(
                    data: (identity) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          identity.encodedPublicKey,
                          style: const TextStyle(
                            color: MobileUiTokens.mutedInk,
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Key ID: ${identity.keyId} (v${identity.keyVersion})',
                                style: MobileUiTokens.subtitle.copyWith(
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            TextButton.icon(
                              style: MobileButtonStyles.redText,
                              onPressed: () =>
                                  onCopyPublicKey(identity.encodedPublicKey),
                              icon: const Icon(Icons.key_rounded, size: 18),
                              label: const Text('Copy key'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Signing public key',
                          style: TextStyle(
                            fontFamily: MobileUiTokens.fontFamily,
                            color: MobileUiTokens.deepRed,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ref
                            .watch(deviceSigningIdentityProvider)
                            .when(
                              data: (signing) => Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SelectableText(
                                    signing.encodedPublicKey,
                                    style: const TextStyle(
                                      color: MobileUiTokens.mutedInk,
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                    ),
                                  ),
                                  TextButton.icon(
                                    style: MobileButtonStyles.redText,
                                    onPressed: () async {
                                      await ActionFeedback.copy(
                                        context,
                                        signing.encodedPublicKey,
                                        message: 'Signing public key copied.',
                                      );
                                    },
                                    icon: const Icon(Icons.copy, size: 18),
                                    label: const Text('Copy signing key'),
                                  ),
                                ],
                              ),
                              loading: () => const LinearProgressIndicator(
                                color: MobileUiTokens.brandRed,
                                backgroundColor: MobileUiTokens.redTint,
                              ),
                              error: (_, _) => const Text(
                                'Unable to load signing key. Reopen this screen to retry.',
                                style: MobileUiTokens.subtitle,
                              ),
                            ),
                      ],
                    ),
                    loading: () => const LinearProgressIndicator(
                      color: MobileUiTokens.brandRed,
                      backgroundColor: MobileUiTokens.redTint,
                    ),
                    error: (error, _) => Text(
                      'Unable to load encryption key: $error',
                      style: const TextStyle(color: MobileUiTokens.warningFg),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        loading: () => const Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: MobileUiTokens.brandRed,
              ),
            ),
            SizedBox(width: 10),
            Text('Loading device ID...', style: MobileUiTokens.subtitle),
          ],
        ),
        error: (error, _) => Text(
          'Unable to load device ID: $error',
          style: const TextStyle(
            color: MobileUiTokens.warningFg,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _DeviceRegistrationQrDialog extends StatefulWidget {
  const _DeviceRegistrationQrDialog({required this.registration});

  final DeviceRegistrationQr registration;

  @override
  State<_DeviceRegistrationQrDialog> createState() =>
      _DeviceRegistrationQrDialogState();
}

class _DeviceRegistrationQrDialogState
    extends State<_DeviceRegistrationQrDialog> {
  String? _copyMessage;
  FeedbackKind _copyKind = FeedbackKind.success;
  bool _copying = false;

  @override
  Widget build(BuildContext context) {
    final registration = widget.registration;
    final payload = registration.toJsonString();
    return AlertDialog(
      backgroundColor: MobileUiTokens.canvas,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MobileUiTokens.cardRadius),
      ),
      title: const Text(
        'Your registration code',
        style: MobileUiTokens.sectionHeading,
      ),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(
                    MobileUiTokens.controlRadius,
                  ),
                  border: Border.all(color: MobileUiTokens.border),
                ),
                child: SizedBox.square(
                  dimension: 232,
                  child: CustomPaint(
                    painter: QrPainter(
                      data: payload,
                      version: QrVersions.auto,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: Colors.black,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                registration.deviceId,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: MobileUiTokens.deepRed,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Show this code to the campus administrator.',
                textAlign: TextAlign.center,
                style: MobileUiTokens.subtitle,
              ),
              if (_copyMessage != null) ...[
                const SizedBox(height: 12),
                ActionStatus(message: _copyMessage!, kind: _copyKind),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          style: MobileButtonStyles.redText,
          onPressed: _copying
              ? null
              : () async {
                  setState(() => _copying = true);
                  try {
                    await Clipboard.setData(ClipboardData(text: payload));
                    if (mounted) {
                      setState(() {
                        _copyMessage = 'Registration text copied.';
                        _copyKind = FeedbackKind.success;
                      });
                    }
                  } catch (_) {
                    if (mounted) {
                      setState(() {
                        _copyMessage =
                            'Could not copy the registration text. Try again.';
                        _copyKind = FeedbackKind.error;
                      });
                    }
                  } finally {
                    if (mounted) setState(() => _copying = false);
                  }
                },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('Copy registration text'),
        ),
        FilledButton(
          style: MobileButtonStyles.primaryFilled,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ImportActions extends StatelessWidget {
  const _ImportActions({
    required this.isImporting,
    required this.onScanQr,
    required this.onImportClipboard,
  });

  final bool isImporting;
  final VoidCallback onScanQr;
  final VoidCallback onImportClipboard;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          style: MobileButtonStyles.darkFilled,
          onPressed: isImporting ? null : onScanQr,
          icon: const Icon(Icons.qr_code_scanner_rounded),
          label: Text(isImporting ? 'Checking code...' : 'Scan approval code'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          style: MobileButtonStyles.secondaryOutlined,
          onPressed: isImporting ? null : onImportClipboard,
          icon: const Icon(Icons.paste_rounded, size: 18),
          label: const Text('Paste copied code'),
        ),
      ],
    );
  }
}

class _ManualImportCard extends StatelessWidget {
  const _ManualImportCard({
    required this.controller,
    required this.isImporting,
    required this.onImport,
  });

  final TextEditingController controller;
  final bool isImporting;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Enter approval text', style: MobileUiTokens.sectionHeading),
        const SizedBox(height: 4),
        const Text(
          'Use the text supplied by the campus administrator.',
          style: MobileUiTokens.subtitle,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: controller,
          minLines: 5,
          maxLines: 8,
          decoration: MobileInputStyles.decoration(
            hintText: 'Paste approval text here',
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: MobileButtonStyles.primaryFilled,
            onPressed: isImporting ? null : onImport,
            child: Text(isImporting ? 'Checking...' : 'Save approval update'),
          ),
        ),
      ],
    );
  }
}

class _BundleSummaryCard extends StatelessWidget {
  const _BundleSummaryCard({required this.bundle, required this.onClear});

  final TrustBundle? bundle;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return _TrustPanel(
      title: 'Saved approval update',
      subtitle: 'The latest update from the campus administrator.',
      child: bundle == null
          ? const Text(
              'No approval update saved. You can still send an SOS.',
              style: MobileUiTokens.subtitle,
            )
          : Column(
              children: [
                _SummaryRow(
                  label: 'Bundle version',
                  value: '${bundle!.bundleVersion}',
                ),
                _SummaryRow(
                  label: 'Signature',
                  value: bundle!.isSignatureVerified
                      ? 'Verified Ed25519'
                      : 'Not verified',
                ),
                _SummaryRow(
                  label: 'Issued at',
                  value: (bundle!.issuedAt ?? bundle!.generatedAt)
                      .toLocal()
                      .toString(),
                ),
                _SummaryRow(
                  label: 'Expires at',
                  value: bundle!.expiresAt?.toLocal().toString() ?? 'Unknown',
                ),
                _SummaryRow(
                  label: 'Imported at',
                  value: bundle!.importedAt?.toLocal().toString() ?? 'Legacy',
                ),
                _SummaryRow(
                  label: 'Administrator key',
                  value: bundle!.issuer?.signingKeyId ?? 'Not pinned',
                  monospace: true,
                ),
                _SummaryRow(
                  label: 'Approved devices',
                  value: '${bundle!.approvedCount}',
                ),
                _SummaryRow(
                  label: 'Revoked devices',
                  value: '${bundle!.revokedCount}',
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: MobileButtonStyles.secondaryOutlined.copyWith(
                      foregroundColor: const WidgetStatePropertyAll(
                        MobileUiTokens.errorFg,
                      ),
                      side: const WidgetStatePropertyAll(
                        BorderSide(color: MobileUiTokens.errorBorder),
                      ),
                    ),
                    onPressed: onClear,
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: const Text('Remove saved approval'),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MobileStatusBanner(
      liveRegion: true,
      tone: MobileStatusTone.warning,
      message: message,
    );
  }
}

class _TrustPanel extends StatelessWidget {
  const _TrustPanel({
    this.stepLabel,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String? stepLabel;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MobileSectionCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stepLabel case final stepLabel?) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: MobileUiTokens.redTint,
                borderRadius: BorderRadius.circular(MobileUiTokens.pillRadius),
              ),
              child: Text(
                stepLabel.toUpperCase(),
                style: MobileUiTokens.badgeText.copyWith(
                  fontSize: 11,
                  color: MobileUiTokens.brandRed,
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(title, style: MobileUiTokens.sectionHeading),
          const SizedBox(height: 4),
          Text(subtitle, style: MobileUiTokens.subtitle),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: MobileUiTokens.subtitle)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: MobileUiTokens.bodyStrong.copyWith(
                fontSize: 13.5,
                fontFamily: monospace ? 'monospace' : MobileUiTokens.fontFamily,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
