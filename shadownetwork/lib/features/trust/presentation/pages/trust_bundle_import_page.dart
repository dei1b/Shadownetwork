import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../messaging/domain/entities/peer.dart';
import '../../../messaging/presentation/providers/local_messaging_providers.dart';
import '../../../security/domain/entities/device_crypto_identity.dart';
import '../../../security/domain/entities/device_registration_qr.dart';
import '../../data/services/trust_bundle_store.dart';
import '../../domain/entities/trust_bundle.dart';
import '../providers/device_access_provider.dart';

const _trustRed = Color(0xFFE83C3D);
const _trustRedDark = Color(0xFF861A1A);
const _trustMuted = Color(0xFF666666);
const _trustField = Color(0xFFE1E1E1);

class TrustBundleImportPage extends ConsumerStatefulWidget {
  const TrustBundleImportPage({super.key});

  @override
  ConsumerState<TrustBundleImportPage> createState() =>
      _TrustBundleImportPageState();
}

class _TrustBundleImportPageState extends ConsumerState<TrustBundleImportPage> {
  final TrustBundleStore _store = TrustBundleStore();
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
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _error = 'Unable to load trust bundle: $error';
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
      _showSnackBar('Clipboard does not contain a trust bundle.');
      return;
    }
    await _importBundle(text);
  }

  Future<void> _importFromTextField() async {
    await _importBundle(_jsonController.text);
  }

  Future<void> _copyDeviceId(String deviceId) async {
    await Clipboard.setData(ClipboardData(text: deviceId));
    _showSnackBar('Device ID copied.');
  }

  Future<void> _copyPublicKey(String publicKey) async {
    await Clipboard.setData(ClipboardData(text: publicKey));
    _showSnackBar('X25519 public key copied.');
  }

  Future<void> _showDeviceRegistrationQr(
    Peer peer,
    DeviceCryptoIdentity identity,
  ) async {
    final registration = DeviceRegistrationQr.fromIdentity(
      deviceId: peer.id,
      identity: identity,
    );
    await showDialog<void>(
      context: context,
      builder: (context) =>
          _DeviceRegistrationQrDialog(registration: registration),
    );
  }

  Future<void> _importBundle(String source) async {
    if (_isImporting) {
      return;
    }
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
      final repository = await ref.read(trustRepositoryProvider.future);
      await repository.replaceFromBundle(bundle);
      if (!mounted) {
        return;
      }
      setState(() {
        _bundle = bundle;
        _jsonController.clear();
      });
      ref.invalidate(deviceAccessProfileProvider);
      _showSnackBar(
        'Verified signed bundle v${bundle.bundleVersion}: ${bundle.approvedCount} approved and ${bundle.revokedCount} revoked devices.',
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.message);
      _showSnackBar('Invalid trust bundle.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = 'Import failed: $error');
      _showSnackBar('Import failed.');
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
          title: const Text('Trust this PC administrator?'),
          content: Text(
            'This is the first signed trust bundle on this phone. Confirm that the QR is displayed by your authorized Shadow Network administrator.\n\nSigning key: ${bundle.issuer?.signingKeyId ?? 'missing'}\n\nThis administrator key will be pinned for future updates.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Trust administrator'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _clearBundle() async {
    await _store.clearBundle();
    final repository = await ref.read(trustRepositoryProvider.future);
    await repository.clear();
    if (!mounted) {
      return;
    }
    setState(() => _bundle = null);
    ref.invalidate(deviceAccessProfileProvider);
    _showSnackBar('Trust bundle removed from this phone.');
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final localPeer = ref.watch(localPeerProvider);
    final cryptoIdentity = ref.watch(deviceCryptoIdentityProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Trust Bundle'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: _trustRed))
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _TrustHeader(bundle: _bundle),
                    const SizedBox(height: 18),
                    _DeviceIdentityCard(
                      localPeer: localPeer,
                      cryptoIdentity: cryptoIdentity,
                      onCopyDeviceId: _copyDeviceId,
                      onCopyPublicKey: _copyPublicKey,
                      onShowRegistrationQr: _showDeviceRegistrationQr,
                    ),
                    const SizedBox(height: 18),
                    _ImportActions(
                      isImporting: _isImporting,
                      onScanQr: _scanQr,
                      onImportClipboard: _importFromClipboard,
                    ),
                    const SizedBox(height: 18),
                    _ManualImportCard(
                      controller: _jsonController,
                      isImporting: _isImporting,
                      onImport: _importFromTextField,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      _ErrorCard(message: _error!),
                    ],
                    const SizedBox(height: 18),
                    _BundleSummaryCard(bundle: _bundle, onClear: _clearBundle),
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
        title: const Text('Scan Admin QR'),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: _trustRed,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 18,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.verified_user_rounded,
            color: Colors.white,
            size: 42,
          ),
          const SizedBox(height: 12),
          const Text(
            'Offline Trust Bundle',
            style: TextStyle(
              color: Colors.white,
              fontSize: 25,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            bundle == null
                ? 'No trusted device list imported yet.'
                : '${bundle!.approvedCount} approved, ${bundle!.revokedCount} revoked devices saved.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.84),
              fontWeight: FontWeight.w700,
            ),
          ),
          if (bundle != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _HeaderBadge(
                  icon: Icons.verified_rounded,
                  label: bundle!.isSignatureVerified
                      ? 'SIGNATURE VERIFIED'
                      : 'LEGACY UNSIGNED',
                ),
                _HeaderBadge(
                  icon: Icons.layers_rounded,
                  label: 'VERSION ${bundle!.bundleVersion}',
                ),
                if (bundle!.isExpiredAt(DateTime.now()))
                  const _HeaderBadge(
                    icon: Icons.warning_amber_rounded,
                    label: 'EXPIRED',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HeaderBadge extends StatelessWidget {
  const _HeaderBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceIdentityCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return _TrustPanel(
      title: 'This Phone Device ID',
      subtitle: 'Register this exact ID in the PC admin dashboard.',
      child: localPeer.when(
        data: (peer) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7F7),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _trustField),
              ),
              child: SelectableText(
                peer.id,
                style: const TextStyle(
                  color: _trustRedDark,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
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
                    style: const TextStyle(color: _trustMuted),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => onCopyDeviceId(peer.id),
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copy'),
                ),
              ],
            ),
            const Divider(height: 24),
            const Text(
              'Encryption public key',
              style: TextStyle(
                color: _trustRedDark,
                fontWeight: FontWeight.w800,
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
                      color: _trustMuted,
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
                          style: const TextStyle(
                            color: _trustMuted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            onCopyPublicKey(identity.encodedPublicKey),
                        icon: const Icon(Icons.key_rounded),
                        label: const Text('Copy key'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => onShowRegistrationQr(peer, identity),
                      style: FilledButton.styleFrom(
                        backgroundColor: _trustRed,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                      ),
                      icon: const Icon(Icons.qr_code_2_rounded),
                      label: const Text('Show PC Registration QR'),
                    ),
                  ),
                ],
              ),
              loading: () => const LinearProgressIndicator(color: _trustRed),
              error: (error, _) => Text(
                'Unable to load encryption key: $error',
                style: const TextStyle(color: Color(0xFF9A5A00)),
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
                color: _trustRed,
              ),
            ),
            SizedBox(width: 10),
            Text('Loading device ID...'),
          ],
        ),
        error: (error, _) => Text(
          'Unable to load device ID: $error',
          style: const TextStyle(
            color: Color(0xFF9A5A00),
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _DeviceRegistrationQrDialog extends StatelessWidget {
  const _DeviceRegistrationQrDialog({required this.registration});

  final DeviceRegistrationQr registration;

  @override
  Widget build(BuildContext context) {
    final payload = registration.toJsonString();
    return AlertDialog(
      backgroundColor: Colors.white,
      title: const Text(
        'Device Registration QR',
        style: TextStyle(fontWeight: FontWeight.w900),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              color: Colors.white,
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
                color: _trustRedDark,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'On the PC admin dashboard, select Scan Phone QR and point the PC camera at this code.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _trustMuted, fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: payload));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Registration JSON copied.')),
              );
            }
          },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Copy JSON'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          style: FilledButton.styleFrom(backgroundColor: _trustRed),
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
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _trustRed,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(54),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: isImporting ? null : onScanQr,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('Scan QR'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: _trustRedDark,
              side: const BorderSide(color: _trustRed),
              minimumSize: const Size.fromHeight(54),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: isImporting ? null : onImportClipboard,
            icon: const Icon(Icons.paste_rounded),
            label: const Text('Clipboard'),
          ),
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
    return _TrustPanel(
      title: 'Manual Import',
      subtitle: 'Paste the JSON trust bundle if QR scanning is unavailable.',
      child: Column(
        children: [
          TextField(
            controller: controller,
            minLines: 5,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: 'Paste trust bundle JSON here...',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: isImporting ? null : onImport,
              child: Text(isImporting ? 'Importing...' : 'Import Bundle'),
            ),
          ),
        ],
      ),
    );
  }
}

class _BundleSummaryCard extends StatelessWidget {
  const _BundleSummaryCard({required this.bundle, required this.onClear});

  final TrustBundle? bundle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return _TrustPanel(
      title: 'Current Phone Trust State',
      subtitle: 'Signed administrator policy used by messaging and relay.',
      child: bundle == null
          ? const Text(
              'No bundle imported. SOS messages from unknown devices should still be shown but labeled unverified.',
              style: TextStyle(color: _trustMuted),
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
                ),
                _SummaryRow(
                  label: 'Approved devices',
                  value: '${bundle!.approvedCount}',
                ),
                _SummaryRow(
                  label: 'Revoked devices',
                  value: '${bundle!.revokedCount}',
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onClear,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Clear Imported Bundle'),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF5E6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFD28A)),
      ),
      child: Text(
        message,
        style: const TextStyle(
          color: Color(0xFF9A5A00),
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _TrustPanel extends StatelessWidget {
  const _TrustPanel({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _trustField),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: _trustMuted)),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: _trustMuted)),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}
