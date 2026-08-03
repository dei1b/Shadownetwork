import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../messaging/domain/entities/peer.dart';
import '../../../messaging/presentation/providers/local_messaging_providers.dart';
import '../../data/services/trust_bundle_store.dart';
import '../../domain/entities/trust_bundle.dart';

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

  Future<void> _importBundle(String source) async {
    if (_isImporting) {
      return;
    }
    setState(() {
      _isImporting = true;
      _error = null;
    });

    try {
      final bundle = await _store.importBundleJson(source.trim());
      if (!mounted) {
        return;
      }
      setState(() {
        _bundle = bundle;
        _jsonController.clear();
      });
      _showSnackBar(
        'Imported ${bundle.approvedCount} approved and ${bundle.revokedCount} revoked devices.',
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

  Future<void> _clearBundle() async {
    await _store.clearBundle();
    if (!mounted) {
      return;
    }
    setState(() => _bundle = null);
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
                      onCopyDeviceId: _copyDeviceId,
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
        ],
      ),
    );
  }
}

class _DeviceIdentityCard extends StatelessWidget {
  const _DeviceIdentityCard({
    required this.localPeer,
    required this.onCopyDeviceId,
  });

  final AsyncValue<Peer> localPeer;
  final ValueChanged<String> onCopyDeviceId;

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
      subtitle:
          'Used later to label verified, unverified, and revoked senders.',
      child: bundle == null
          ? const Text(
              'No bundle imported. SOS messages from unknown devices should still be shown but labeled unverified.',
              style: TextStyle(color: _trustMuted),
            )
          : Column(
              children: [
                _SummaryRow(
                  label: 'Generated at',
                  value: bundle!.generatedAt.toLocal().toString(),
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
