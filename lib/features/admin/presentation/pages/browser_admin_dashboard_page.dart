import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/services/admin_device_registry_store.dart';
import '../../domain/entities/registered_device.dart';
import '../../domain/repositories/admin_registry_repository.dart';
import '../widgets/registration_json_dialog.dart';
import '../widgets/admin_device_registry_panel.dart';
import '../../../security/domain/entities/device_registration_qr.dart';
import '../../../trust/domain/entities/trust_bundle.dart';

const _mobileRed = Color(0xFFB52B32);
const _mobileRedDark = Color(0xFF861A1A);
const _mobileMuted = Color(0xFF666666);
const _mobileField = Color(0xFFE1E1E1);

class BrowserAdminDashboardPage extends StatefulWidget {
  const BrowserAdminDashboardPage({
    super.key,
    this.registry,
    this.desktopMode = false,
    this.validationPanel,
  });

  final AdminRegistryRepository? registry;
  final bool desktopMode;
  final Widget? validationPanel;

  @override
  State<BrowserAdminDashboardPage> createState() =>
      _BrowserAdminDashboardPageState();
}

class _BrowserAdminDashboardPageState extends State<BrowserAdminDashboardPage> {
  final AdminDeviceRegistryStore _browserRegistry = AdminDeviceRegistryStore();
  AdminRegistryRepository get _registryStore =>
      widget.registry ?? _browserRegistry;
  final TextEditingController _deviceIdController = TextEditingController();
  final TextEditingController _ownerController = TextEditingController();
  final TextEditingController _publicKeyController = TextEditingController();
  final TextEditingController _signingKeyController = TextEditingController();

  List<RegisteredDevice> _devices = const [];
  RegisteredDeviceRole _selectedRole = RegisteredDeviceRole.civilian;
  int _registrationKeyVersion = 1;
  bool _isLoadingRegistry = true;
  bool _isSavingRegistry = false;
  String? _registryError;

  @override
  void initState() {
    super.initState();
    _loadRegistry();
  }

  @override
  void dispose() {
    _deviceIdController.dispose();
    _ownerController.dispose();
    _publicKeyController.dispose();
    _signingKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadRegistry() async {
    try {
      final devices = await _registryStore.loadDevices();
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = devices;
        _isLoadingRegistry = false;
        _registryError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoadingRegistry = false;
        _registryError =
            'Unable to load the device registry. Check available storage and try again.';
      });
    }
  }

  Future<bool> _saveDevices(List<RegisteredDevice> devices) async {
    if (_isSavingRegistry) return false;
    setState(() => _isSavingRegistry = true);
    try {
      await _registryStore.saveDevices(devices);
      if (!mounted) return false;
      setState(() => _devices = devices);
      return true;
    } catch (_) {
      _showSnackBar(
        'Unable to save the registry. Check available storage and try again.',
      );
      return false;
    } finally {
      if (mounted) setState(() => _isSavingRegistry = false);
    }
  }

  Future<void> _registerDevice() async {
    final deviceId = _deviceIdController.text.trim();
    final owner = _ownerController.text.trim();
    final publicKey = _publicKeyController.text.trim();
    final signingPublicKey = _signingKeyController.text.trim();
    if (deviceId.isEmpty ||
        owner.isEmpty ||
        publicKey.isEmpty ||
        signingPublicKey.isEmpty) {
      _showSnackBar(
        'User name, device ID, encryption key, and signing key are required.',
      );
      return;
    }
    if (!_isValidX25519PublicKey(publicKey) ||
        !_isValidX25519PublicKey(signingPublicKey)) {
      _showSnackBar(
        'Encryption and signing public keys must each contain 32 bytes.',
      );
      return;
    }

    final alreadyRegistered = _devices.any(
      (device) =>
          device.deviceId.trim().toLowerCase() == deviceId.toLowerCase(),
    );
    if (alreadyRegistered) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace phone keys for this user?'),
          content: const Text(
            'The replacement requires approval and a new trust bundle. Previously encrypted messages still require the old phone key.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Replace and review'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    final now = DateTime.now().toUtc();
    final nextDevices = [
      RegisteredDevice(
        deviceId: deviceId,
        ownerName: owner,
        role: _selectedRole,
        status: RegisteredDeviceStatus.pending,
        registeredAt: now,
        updatedAt: now,
        lastSeenLabel: 'New registration',
        publicKey: publicKey,
        signingPublicKey: signingPublicKey,
        keyVersion: _registrationKeyVersion,
      ),
      ..._devices.where(
        (device) =>
            device.deviceId.trim().toLowerCase() != deviceId.toLowerCase(),
      ),
    ];

    if (!await _saveDevices(nextDevices) || !mounted) return;
    _deviceIdController.clear();
    _ownerController.clear();
    _publicKeyController.clear();
    _signingKeyController.clear();
    setState(() {
      _selectedRole = RegisteredDeviceRole.civilian;
      _registrationKeyVersion = 1;
    });
    _showSnackBar('$deviceId saved as pending approval.');
  }

  Future<void> _scanDeviceRegistrationQr() async {
    final String? source;
    if (widget.desktopMode) {
      source = await showDialog<String>(
        context: context,
        builder: (_) => const RegistrationJsonDialog(),
      );
    } else {
      source = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => const _DeviceRegistrationScannerPage(),
        ),
      );
    }
    if (source == null || source.trim().isEmpty || !mounted) {
      return;
    }

    try {
      final registration = DeviceRegistrationQr.fromJsonString(source);
      await registration.verifySignature();
      if (!mounted) return;
      setState(() {
        _deviceIdController.text = registration.deviceId;
        _publicKeyController.text = registration.publicKey;
        _registrationKeyVersion = registration.keyVersion;
        _signingKeyController.text = registration.signingPublicKey!;
        for (final device in _devices) {
          if (device.deviceId.toLowerCase() ==
              registration.deviceId.toLowerCase()) {
            _ownerController.text = device.ownerName;
            _selectedRole = device.role;
            break;
          }
        }
      });
      _showSnackBar(
        'Phone registration signature checked. Enter the user name and role.',
      );
    } on FormatException catch (error) {
      _showSnackBar(error.message);
    }
  }

  bool _isValidX25519PublicKey(String value) {
    try {
      return base64Url.decode(value).length == 32;
    } catch (_) {
      return false;
    }
  }

  Future<void> _changeStatus(
    RegisteredDevice device,
    RegisteredDeviceStatus status,
  ) async {
    final now = DateTime.now().toUtc();
    final nextDevices = _devices
        .map(
          (item) => item.deviceId == device.deviceId
              ? item.copyWith(
                  status: status,
                  updatedAt: now,
                  lastSeenLabel: status == RegisteredDeviceStatus.approved
                      ? 'Approved locally - share updated trust bundle'
                      : status == RegisteredDeviceStatus.revoked
                      ? 'Revoked by admin'
                      : item.lastSeenLabel,
                )
              : item,
        )
        .toList(growable: false);

    if (!await _saveDevices(nextDevices)) return;
    _showSnackBar(
      '${device.deviceId} marked ${status.label.toLowerCase()}. '
      'Export a new trust bundle and import it on each phone.',
    );
  }

  Future<void> _editDevice(RegisteredDevice device) async {
    final ownerController = TextEditingController(text: device.ownerName);
    final formKey = GlobalKey<FormState>();
    var selectedRole = device.role;

    final result = await showDialog<_DeviceEditResult>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Edit registered user'),
              content: SizedBox(
                width: 440,
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'DEVICE ID',
                        style: TextStyle(
                          color: _mobileMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.7,
                        ),
                      ),
                      const SizedBox(height: 5),
                      SelectableText(
                        device.deviceId,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 18),
                      TextFormField(
                        controller: ownerController,
                        decoration: const InputDecoration(
                          labelText: 'User full name / Unit name',
                          prefixIcon: Icon(Icons.person_outline_rounded),
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'User full name or unit name is required.'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<RegisteredDeviceRole>(
                        initialValue: selectedRole,
                        decoration: const InputDecoration(
                          labelText: 'Device role',
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                        items: RegisteredDeviceRole.values
                            .map(
                              (role) => DropdownMenuItem(
                                value: role,
                                child: Text(role.label),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => selectedRole = value);
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.desktopMode
                            ? 'To replace phone keys, paste the new registration JSON and register the same device ID again. The replacement requires approval.'
                            : 'To replace phone keys, scan the new registration QR and register the same device ID again. The replacement requires approval.',
                        style: TextStyle(
                          color: _mobileMuted,
                          fontSize: 14,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _mobileRed,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    if (formKey.currentState?.validate() != true) {
                      return;
                    }
                    Navigator.of(context).pop(
                      _DeviceEditResult(
                        ownerName: ownerController.text.trim(),
                        role: selectedRole,
                      ),
                    );
                  },
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Save changes'),
                ),
              ],
            );
          },
        );
      },
    );
    ownerController.dispose();

    if (result == null || !mounted) {
      return;
    }

    final now = DateTime.now().toUtc();
    final nextDevices = _devices
        .map(
          (item) => item.deviceId == device.deviceId
              ? item.copyWith(
                  ownerName: result.ownerName,
                  role: result.role,
                  updatedAt: now,
                  lastSeenLabel: 'Edited by admin',
                )
              : item,
        )
        .toList(growable: false);
    if (!await _saveDevices(nextDevices)) return;
    _showSnackBar('${device.deviceId} updated. Export a new trust bundle.');
  }

  Future<void> _deleteDevice(RegisteredDevice device) async {
    final removesSecurityRecord =
        device.status != RegisteredDeviceStatus.pending;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete registered device?'),
          content: Text(
            removesSecurityRecord
                ? 'This permanently removes ${device.deviceId} from the admin registry, including its ${device.status.label.toLowerCase()} security record. Export and import a new trust bundle after deletion.'
                : 'This permanently removes the pending registration for ${device.deviceId}.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _mobileRedDark,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.delete_forever_rounded, size: 18),
              label: const Text('Delete permanently'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) {
      return;
    }

    final nextDevices = _devices
        .where((item) => item.deviceId != device.deviceId)
        .toList(growable: false);
    if (!await _saveDevices(nextDevices)) return;
    _showSnackBar('${device.deviceId} deleted from the registry.');
  }

  Future<void> _copyTrustBundle() async {
    try {
      final bundle = await _registryStore.buildTrustBundleJson(_devices);
      final parsed = TrustBundle.fromJsonString(bundle);
      await Clipboard.setData(ClipboardData(text: bundle));
      _showSnackBar(
        'Signed trust bundle v${parsed.bundleVersion} copied to clipboard.',
      );
    } on FormatException catch (error) {
      _showSnackBar(error.message);
    } on StateError catch (error) {
      _showSnackBar(error.message.toString());
    } catch (_) {
      _showSnackBar(
        'Unable to publish the trust bundle. Check Backup & recovery and available storage.',
      );
    }
  }

  Future<void> _showTrustBundleQr() async {
    late final String bundle;
    try {
      bundle = await _registryStore.buildTrustBundleJson(_devices);
    } on FormatException catch (error) {
      _showSnackBar(error.message);
      return;
    } on StateError catch (error) {
      _showSnackBar(error.message.toString());
      return;
    } catch (_) {
      _showSnackBar(
        'Unable to publish the trust bundle. Check Backup & recovery and available storage.',
      );
      return;
    }
    final parsed = TrustBundle.fromJsonString(bundle);
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Scan Signed Trust Bundle v${parsed.bundleVersion}'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Open Trust Bundle on the phone and scan this QR.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.white,
                  child: QrImageView(
                    data: bundle,
                    version: QrVersions.auto,
                    size: 280,
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    errorStateBuilder: (context, error) {
                      return const SizedBox(
                        width: 280,
                        height: 280,
                        child: Center(
                          child: Text(
                            'Bundle is too large for one QR. Use Copy JSON instead.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: bundle));
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
                _showSnackBar('Offline trust bundle copied to clipboard.');
              },
              icon: const Icon(Icons.content_copy_rounded),
              label: const Text('Copy JSON'),
            ),
          ],
        );
      },
    );
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _isLoadingRegistry
        ? const _LoadingRegistry()
        : _registryError != null
        ? _RegistryError(message: _registryError!, onRetry: _loadRegistry)
        : _AdminDashboardBody(
            isSaving: _isSavingRegistry,
            desktopMode: widget.desktopMode,
            validationPanel: widget.validationPanel,
            devices: _devices,
            selectedRole: _selectedRole,
            deviceIdController: _deviceIdController,
            ownerController: _ownerController,
            publicKeyController: _publicKeyController,
            signingKeyController: _signingKeyController,
            onRoleChanged: (value) => setState(() => _selectedRole = value),
            onRegister: _registerDevice,
            onScanRegistrationQr: _scanDeviceRegistrationQr,
            onApprove: (device) =>
                _changeStatus(device, RegisteredDeviceStatus.approved),
            onRevoke: (device) =>
                _changeStatus(device, RegisteredDeviceStatus.revoked),
            onEdit: _editDevice,
            onDelete: _deleteDevice,
            onCopyTrustBundle: _copyTrustBundle,
            onShowTrustBundleQr: _showTrustBundleQr,
          );

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: body,
      bottomSheet: _isSavingRegistry
          ? Material(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Semantics(
                        liveRegion: true,
                        child: const Text('Saving registry changes...'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

class _AdminDashboardBody extends StatelessWidget {
  const _AdminDashboardBody({
    this.desktopMode = false,
    this.isSaving = false,
    this.validationPanel,
    required this.devices,
    required this.selectedRole,
    required this.deviceIdController,
    required this.ownerController,
    required this.publicKeyController,
    required this.signingKeyController,
    required this.onRoleChanged,
    required this.onRegister,
    required this.onScanRegistrationQr,
    required this.onApprove,
    required this.onRevoke,
    required this.onEdit,
    required this.onDelete,
    required this.onCopyTrustBundle,
    required this.onShowTrustBundleQr,
  });

  final List<RegisteredDevice> devices;
  final bool desktopMode;
  final bool isSaving;
  final Widget? validationPanel;
  final RegisteredDeviceRole selectedRole;
  final TextEditingController deviceIdController;
  final TextEditingController ownerController;
  final TextEditingController publicKeyController;
  final TextEditingController signingKeyController;
  final ValueChanged<RegisteredDeviceRole> onRoleChanged;
  final VoidCallback onRegister;
  final VoidCallback onScanRegistrationQr;
  final ValueChanged<RegisteredDevice> onApprove;
  final ValueChanged<RegisteredDevice> onRevoke;
  final ValueChanged<RegisteredDevice> onEdit;
  final ValueChanged<RegisteredDevice> onDelete;
  final VoidCallback onCopyTrustBundle;
  final VoidCallback onShowTrustBundleQr;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _Header(deviceCount: devices.length, desktopMode: desktopMode),
        ),
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1320),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 36),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (devices.isNotEmpty) ...[
                      _MetricsRow(devices: devices),
                      const SizedBox(height: 22),
                    ],
                    _ResponsiveSplit(
                      left: devices.isEmpty
                          ? _Panel(
                              title: 'Add your first phone',
                              subtitle:
                                  'On the phone, open Trust Bundle and copy its registration JSON. Paste it here to check the signature, then enter the name and role.',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  FilledButton.icon(
                                    key: const ValueKey(
                                      'admin-first-registration',
                                    ),
                                    onPressed: isSaving
                                        ? null
                                        : onScanRegistrationQr,
                                    icon: const Icon(Icons.add_circle_outline),
                                    label: const Text('Register a phone'),
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'You can also enter registration details in the form below.',
                                  ),
                                ],
                              ),
                            )
                          : AdminDeviceRegistryPanel(
                              busy: isSaving,
                              devices: devices,
                              onApprove: onApprove,
                              onRevoke: onRevoke,
                              onEdit: onEdit,
                              onDelete: onDelete,
                            ),
                      right: Column(
                        children: [
                          _RegisterDeviceCard(
                            busy: isSaving,
                            desktopMode: desktopMode,
                            deviceIdController: deviceIdController,
                            ownerController: ownerController,
                            publicKeyController: publicKeyController,
                            signingKeyController: signingKeyController,
                            selectedRole: selectedRole,
                            onRoleChanged: onRoleChanged,
                            onRegister: onRegister,
                            onScanRegistrationQr: onScanRegistrationQr,
                          ),
                          const SizedBox(height: 22),
                          _SecurityModelCard(
                            busy: isSaving,
                            onCopyTrustBundle: onCopyTrustBundle,
                            onShowTrustBundleQr: onShowTrustBundleQr,
                          ),
                          const SizedBox(height: 22),
                          validationPanel ?? const _ValidationMetricsCard(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LoadingRegistry extends StatelessWidget {
  const _LoadingRegistry();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: _mobileRed),
          SizedBox(height: 14),
          Text('Loading admin registry...'),
        ],
      ),
    );
  }
}

class _RegistryError extends StatelessWidget {
  const _RegistryError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: _Panel(
        title: 'Registry Unavailable',
        subtitle: message,
        child: FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Retry'),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.deviceCount, this.desktopMode = false});

  final int deviceCount;
  final bool desktopMode;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1272),
          child: SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    desktopMode ? 'Devices' : 'Shadow Network Admin',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF222222),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  desktopMode
                      ? 'Manage phone approvals and share trust updates. Your registry is saved on this computer.'
                      : 'Manage phone approvals and share trust updates. Your registry is saved in this browser.',
                  style: const TextStyle(color: _mobileMuted, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricsRow extends StatelessWidget {
  const _MetricsRow({required this.devices});

  final List<RegisteredDevice> devices;

  @override
  Widget build(BuildContext context) {
    final approved = devices
        .where((item) => item.status == RegisteredDeviceStatus.approved)
        .length;
    final pending = devices
        .where((item) => item.status == RegisteredDeviceStatus.pending)
        .length;
    final revoked = devices
        .where((item) => item.status == RegisteredDeviceStatus.revoked)
        .length;
    final responders = devices
        .where((item) => item.role == RegisteredDeviceRole.responder)
        .length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 850
            ? 4
            : constraints.maxWidth >= 460
            ? 2
            : 1;
        final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _MetricCard(
              icon: Icons.verified_rounded,
              label: 'Approved devices',
              value: '$approved',
              detail: 'Included in trust exports',
            ),
            _MetricCard(
              icon: Icons.pending_actions_rounded,
              label: 'Pending review',
              value: '$pending',
              detail: 'Needs admin approval',
            ),
            _MetricCard(
              icon: Icons.block_rounded,
              label: 'Revoked devices',
              value: '$revoked',
              detail: 'Blocked from future trust bundles',
            ),
            _MetricCard(
              icon: Icons.health_and_safety_rounded,
              label: 'Responder endpoints',
              value: '$responders',
              detail: 'Registered with this role',
            ),
          ].map((child) => SizedBox(width: width, child: child)).toList(),
        );
      },
    );
  }
}

class _RegisterDeviceCard extends StatelessWidget {
  const _RegisterDeviceCard({
    this.desktopMode = false,
    this.busy = false,
    required this.deviceIdController,
    required this.ownerController,
    required this.publicKeyController,
    required this.signingKeyController,
    required this.selectedRole,
    required this.onRoleChanged,
    required this.onRegister,
    required this.onScanRegistrationQr,
  });

  final TextEditingController deviceIdController;
  final bool desktopMode;
  final TextEditingController ownerController;
  final TextEditingController publicKeyController;
  final TextEditingController signingKeyController;
  final RegisteredDeviceRole selectedRole;
  final ValueChanged<RegisteredDeviceRole> onRoleChanged;
  final VoidCallback onRegister;
  final VoidCallback onScanRegistrationQr;

  final bool busy;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Register a phone',
      subtitle:
          'Register a user and their phone, then approve their role for offline use.',
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: busy ? null : onScanRegistrationQr,
              style: OutlinedButton.styleFrom(
                foregroundColor: _mobileRed,
                minimumSize: const Size(double.infinity, 52),
                side: const BorderSide(color: _mobileRed),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(
                desktopMode
                    ? 'Paste Phone Registration JSON'
                    : 'Scan Phone QR with PC Camera',
              ),
            ),
          ),
          const SizedBox(height: 14),
          ExpansionTile(
            key: ValueKey(
              'registration-details-${deviceIdController.text.isNotEmpty}',
            ),
            initiallyExpanded: deviceIdController.text.isNotEmpty,
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(top: 12),
            title: const Text('Registration details'),
            subtitle: const Text(
              'Enter or review the phone keys, name and role',
            ),
            maintainState: true,
            children: [
              TextField(
                enabled: !busy,
                controller: deviceIdController,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Device ID',
                  hintText: 'Example: SN-CIVILIAN-104',
                  prefixIcon: Icon(Icons.qr_code_2_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                enabled: !busy,
                controller: ownerController,
                decoration: const InputDecoration(
                  labelText: 'User full name / Unit name',
                  hintText: 'Example: Barangay Health Responder',
                  prefixIcon: Icon(Icons.badge_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                enabled: !busy,
                controller: publicKeyController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'X25519 public key',
                  hintText: 'Paste from the phone Trust Bundle screen',
                  prefixIcon: Icon(Icons.key_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                enabled: !busy,
                controller: signingKeyController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Ed25519 signing public key',
                  hintText: 'Filled from the phone registration QR',
                  prefixIcon: Icon(Icons.verified_user_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<RegisteredDeviceRole>(
                initialValue: selectedRole,
                decoration: const InputDecoration(
                  labelText: 'Role',
                  prefixIcon: Icon(Icons.supervised_user_circle_rounded),
                  border: OutlineInputBorder(),
                ),
                items: RegisteredDeviceRole.values
                    .map(
                      (role) => DropdownMenuItem(
                        value: role,
                        child: Text(role.label),
                      ),
                    )
                    .toList(growable: false),
                onChanged: busy
                    ? null
                    : (value) {
                        if (value != null) {
                          onRoleChanged(value);
                        }
                      },
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _mobileRed,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  onPressed: busy ? null : onRegister,
                  icon: const Icon(Icons.app_registration_rounded),
                  label: const Text('Add to registry'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            desktopMode
                ? 'Saved on this computer. Use Backup & recovery to protect your registry and administrator identity.'
                : 'Saved locally in this browser. During testing, run with the same web port so registrations remain available.',
            style: TextStyle(color: _mobileMuted, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _DeviceRegistrationScannerPage extends StatefulWidget {
  const _DeviceRegistrationScannerPage();

  @override
  State<_DeviceRegistrationScannerPage> createState() =>
      _DeviceRegistrationScannerPageState();
}

class _DeviceRegistrationScannerPageState
    extends State<_DeviceRegistrationScannerPage> {
  bool _handledCode = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101010),
      appBar: AppBar(
        title: const Text('Scan Phone Registration QR'),
        backgroundColor: const Color(0xFF101010),
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
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
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 4),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 30,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Text(
                'Allow camera access, then point the PC camera at the registration QR displayed on the phone.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SecurityModelCard extends StatelessWidget {
  const _SecurityModelCard({
    this.busy = false,
    required this.onCopyTrustBundle,
    required this.onShowTrustBundleQr,
  });

  final VoidCallback onCopyTrustBundle;
  final VoidCallback onShowTrustBundleQr;

  final bool busy;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Share trust updates',
      subtitle: 'Export a signed trust bundle after changing phone approvals.',
      child: Column(
        children: [
          const _InfoRow(
            icon: Icons.phonelink_setup_outlined,
            title: 'Update every participating phone',
            detail:
                'Import the new bundle on each phone. Approval and revocation changes do not sync automatically.',
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _mobileRed,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              onPressed: busy ? null : onShowTrustBundleQr,
              icon: const Icon(Icons.qr_code_2_rounded),
              label: const Text('Show QR for Phone Scan'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: _mobileRedDark,
                side: const BorderSide(color: _mobileRed),
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              onPressed: busy ? null : onCopyTrustBundle,
              icon: const Icon(Icons.content_copy_rounded),
              label: const Text('Copy Trust Bundle JSON'),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceEditResult {
  const _DeviceEditResult({required this.ownerName, required this.role});

  final String ownerName;
  final RegisteredDeviceRole role;
}

class _ValidationMetricsCard extends StatelessWidget {
  const _ValidationMetricsCard();

  @override
  Widget build(BuildContext context) {
    return const _Panel(
      title: 'Validation metrics',
      subtitle: 'Real metrics will appear after SOS and relay logs are synced.',
      child: Column(
        children: [
          _MetricLine(
            label: 'Message delivery success rate',
            value: 'No data',
            detail: 'Requires delivered and received message records.',
          ),
          _MetricLine(
            label: 'Node-to-node latency',
            value: 'No data',
            detail: 'Requires transfer start and received timestamps.',
          ),
          _MetricLine(
            label: 'End-to-end propagation time',
            value: 'No data',
            detail: 'Requires SOS creation time and responder receipt time.',
          ),
          _MetricLine(
            label: 'Hop count distribution',
            value: 'No data',
            detail: 'Requires stored SOS/chat hop counts.',
          ),
          _MetricLine(
            label: 'Battery impact',
            value: 'No data',
            detail: 'Requires battery sampling during relay tests.',
          ),
          _MetricLine(
            label: 'Peer discovery success rate',
            value: 'No data',
            detail: 'Requires scan attempts and discovered peer counts.',
          ),
        ],
      ),
    );
  }
}

class _ResponsiveSplit extends StatelessWidget {
  const _ResponsiveSplit({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 1000 ||
            MediaQuery.textScalerOf(context).scale(1) > 1.5) {
          return Column(children: [left, const SizedBox(height: 22), right]);
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: left),
            const SizedBox(width: 22),
            Expanded(flex: 2, child: right),
          ],
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
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
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: _mobileField),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: const TextStyle(color: _mobileMuted)),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
  });

  final IconData icon;
  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _mobileField),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: const TextStyle(color: _mobileMuted, fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: _mobileRed),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(detail, style: const TextStyle(color: _mobileMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricLine extends StatelessWidget {
  const _MetricLine({
    required this.label,
    required this.value,
    required this.detail,
  });

  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(detail, style: const TextStyle(color: _mobileMuted)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: const TextStyle(
              color: _mobileRed,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
