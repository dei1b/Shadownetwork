import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shadownetwork/features/auth/presentation/widgets/auth_background.dart';

import '../../data/services/admin_device_registry_store.dart';
import '../../domain/entities/registered_device.dart';

const _mobileRed = Color(0xFFE83C3D);
const _mobileRedDark = Color(0xFF861A1A);
const _mobileMuted = Color(0xFF666666);
const _mobileField = Color(0xFFE1E1E1);

class BrowserAdminDashboardPage extends StatefulWidget {
  const BrowserAdminDashboardPage({super.key});

  @override
  State<BrowserAdminDashboardPage> createState() =>
      _BrowserAdminDashboardPageState();
}

class _BrowserAdminDashboardPageState extends State<BrowserAdminDashboardPage> {
  final AdminDeviceRegistryStore _registryStore = AdminDeviceRegistryStore();
  final TextEditingController _deviceIdController = TextEditingController();
  final TextEditingController _ownerController = TextEditingController();

  List<RegisteredDevice> _devices = const [];
  RegisteredDeviceRole _selectedRole = RegisteredDeviceRole.civilian;
  bool _isLoadingRegistry = true;
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
        _registryError = 'Unable to load device registry: $error';
      });
    }
  }

  Future<void> _saveDevices(List<RegisteredDevice> devices) async {
    await _registryStore.saveDevices(devices);
    if (!mounted) {
      return;
    }
    setState(() => _devices = devices);
  }

  Future<void> _registerDevice() async {
    final deviceId = _deviceIdController.text.trim().toUpperCase();
    final owner = _ownerController.text.trim();
    if (deviceId.isEmpty || owner.isEmpty) {
      _showSnackBar('Device ID and owner are required.');
      return;
    }

    final alreadyRegistered = _devices.any(
      (device) => device.deviceId.toUpperCase() == deviceId,
    );
    if (alreadyRegistered) {
      _showSnackBar('$deviceId is already registered.');
      return;
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
      ),
      ..._devices,
    ];

    await _saveDevices(nextDevices);
    _deviceIdController.clear();
    _ownerController.clear();
    setState(() => _selectedRole = RegisteredDeviceRole.civilian);
    _showSnackBar('$deviceId saved as pending approval.');
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
                      ? 'Approved for next sync'
                      : status == RegisteredDeviceStatus.revoked
                      ? 'Revoked by admin'
                      : item.lastSeenLabel,
                )
              : item,
        )
        .toList(growable: false);

    await _saveDevices(nextDevices);
    _showSnackBar('${device.deviceId} marked ${status.label.toLowerCase()}.');
  }

  Future<void> _copyTrustBundle() async {
    final bundle = _registryStore.buildTrustBundleJson(_devices);
    await Clipboard.setData(ClipboardData(text: bundle));
    _showSnackBar('Offline trust bundle copied to clipboard.');
  }

  Future<void> _showTrustBundleQr() async {
    final bundle = _registryStore.buildTrustBundleJson(_devices);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Scan Trust Bundle'),
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
            devices: _devices,
            selectedRole: _selectedRole,
            deviceIdController: _deviceIdController,
            ownerController: _ownerController,
            onRoleChanged: (value) => setState(() => _selectedRole = value),
            onRegister: _registerDevice,
            onApprove: (device) =>
                _changeStatus(device, RegisteredDeviceStatus.approved),
            onRevoke: (device) =>
                _changeStatus(device, RegisteredDeviceStatus.revoked),
            onCopyTrustBundle: _copyTrustBundle,
            onShowTrustBundleQr: _showTrustBundleQr,
          );

    return Scaffold(
      backgroundColor: Colors.white,
      body: AuthBackground(child: body),
    );
  }
}

class _AdminDashboardBody extends StatelessWidget {
  const _AdminDashboardBody({
    required this.devices,
    required this.selectedRole,
    required this.deviceIdController,
    required this.ownerController,
    required this.onRoleChanged,
    required this.onRegister,
    required this.onApprove,
    required this.onRevoke,
    required this.onCopyTrustBundle,
    required this.onShowTrustBundleQr,
  });

  final List<RegisteredDevice> devices;
  final RegisteredDeviceRole selectedRole;
  final TextEditingController deviceIdController;
  final TextEditingController ownerController;
  final ValueChanged<RegisteredDeviceRole> onRoleChanged;
  final VoidCallback onRegister;
  final ValueChanged<RegisteredDevice> onApprove;
  final ValueChanged<RegisteredDevice> onRevoke;
  final VoidCallback onCopyTrustBundle;
  final VoidCallback onShowTrustBundleQr;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _Header(deviceCount: devices.length)),
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1320),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 36),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MetricsRow(devices: devices),
                    const SizedBox(height: 22),
                    _ResponsiveSplit(
                      left: _RegisterDeviceCard(
                        deviceIdController: deviceIdController,
                        ownerController: ownerController,
                        selectedRole: selectedRole,
                        onRoleChanged: onRoleChanged,
                        onRegister: onRegister,
                      ),
                      right: _SecurityModelCard(
                        onCopyTrustBundle: onCopyTrustBundle,
                        onShowTrustBundleQr: onShowTrustBundleQr,
                      ),
                    ),
                    const SizedBox(height: 22),
                    _ResponsiveSplit(
                      left: _DeviceTableCard(
                        devices: devices,
                        onApprove: onApprove,
                        onRevoke: onRevoke,
                      ),
                      right: const _ValidationMetricsCard(),
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
  const _Header({required this.deviceCount});

  final int deviceCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      padding: const EdgeInsets.all(30),
      decoration: BoxDecoration(
        color: _mobileRed,
        borderRadius: BorderRadius.circular(19),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1260),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Image.asset(
                      'assets/home/shadownetwork_logo.png',
                      width: 112,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Shadow Network Admin Dashboard',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Persistent browser registry for device approval, trust control, and validation metrics.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.78),
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _Pill(
                          icon: Icons.devices_other_rounded,
                          label: '$deviceCount tracked devices',
                        ),
                        const _Pill(
                          icon: Icons.verified_user_rounded,
                          label: 'Saved in browser storage',
                        ),
                        const _Pill(
                          icon: Icons.download_for_offline_rounded,
                          label: 'Trust bundle export',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              Container(
                width: 170,
                height: 170,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.72),
                    width: 3,
                  ),
                ),
                child: const Icon(
                  Icons.admin_panel_settings_rounded,
                  color: Colors.white,
                  size: 86,
                ),
              ),
            ],
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
        final columns = constraints.maxWidth >= 980 ? 4 : 2;
        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: columns,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
          childAspectRatio: constraints.maxWidth >= 980 ? 1.9 : 2.4,
          children: [
            _MetricCard(
              icon: Icons.verified_rounded,
              label: 'Approved devices',
              value: '$approved',
              detail: 'Allowed to send verified packets',
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
              detail: 'Can prioritize incoming SOS',
            ),
          ],
        );
      },
    );
  }
}

class _RegisterDeviceCard extends StatelessWidget {
  const _RegisterDeviceCard({
    required this.deviceIdController,
    required this.ownerController,
    required this.selectedRole,
    required this.onRoleChanged,
    required this.onRegister,
  });

  final TextEditingController deviceIdController;
  final TextEditingController ownerController;
  final RegisteredDeviceRole selectedRole;
  final ValueChanged<RegisteredDeviceRole> onRoleChanged;
  final VoidCallback onRegister;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Register Device',
      subtitle:
          'PC admins can approve phones before disaster mode and export the trusted list.',
      child: Column(
        children: [
          TextField(
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
            controller: ownerController,
            decoration: const InputDecoration(
              labelText: 'Owner / Unit name',
              hintText: 'Example: Barangay Health Responder',
              prefixIcon: Icon(Icons.badge_rounded),
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
                  (role) =>
                      DropdownMenuItem(value: role, child: Text(role.label)),
                )
                .toList(growable: false),
            onChanged: (value) {
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
              onPressed: onRegister,
              icon: const Icon(Icons.app_registration_rounded),
              label: const Text('Add to Registry'),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Saved locally in this browser. During testing, run with the same web port so registrations remain available.',
            style: TextStyle(color: _mobileMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _SecurityModelCard extends StatelessWidget {
  const _SecurityModelCard({
    required this.onCopyTrustBundle,
    required this.onShowTrustBundleQr,
  });

  final VoidCallback onCopyTrustBundle;
  final VoidCallback onShowTrustBundleQr;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Anti-Troll Security Model',
      subtitle:
          'The admin dashboard protects the mesh without blocking real victims.',
      child: Column(
        children: [
          const _InfoRow(
            icon: Icons.key_rounded,
            title: 'Signed device certificates',
            detail:
                'Approved phones can later receive credentials that other nodes verify offline.',
          ),
          const _InfoRow(
            icon: Icons.download_for_offline_rounded,
            title: 'Offline trust bundle',
            detail:
                'Phones cache approved and revoked device lists before disaster mode.',
          ),
          const _InfoRow(
            icon: Icons.warning_amber_rounded,
            title: 'Unverified SOS remains visible',
            detail:
                'Unknown devices are labeled unverified instead of fully blocked.',
          ),
          const _InfoRow(
            icon: Icons.block_rounded,
            title: 'Revoke lost devices',
            detail:
                'Admins can mark compromised phones as revoked for future syncs.',
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
              onPressed: onShowTrustBundleQr,
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
              onPressed: onCopyTrustBundle,
              icon: const Icon(Icons.content_copy_rounded),
              label: const Text('Copy Trust Bundle JSON'),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceTableCard extends StatelessWidget {
  const _DeviceTableCard({
    required this.devices,
    required this.onApprove,
    required this.onRevoke,
  });

  final List<RegisteredDevice> devices;
  final ValueChanged<RegisteredDevice> onApprove;
  final ValueChanged<RegisteredDevice> onRevoke;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Device Registry',
      subtitle: 'Approved devices can create verified SOS and relay messages.',
      child: devices.isEmpty
          ? const _RegistryEmptyState()
          : Column(
              children: devices
                  .map(
                    (device) => _DeviceRegistryTile(
                      device: device,
                      onApprove: onApprove,
                      onRevoke: onRevoke,
                    ),
                  )
                  .toList(growable: false),
            ),
    );
  }
}

class _RegistryEmptyState extends StatelessWidget {
  const _RegistryEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7F7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _mobileField),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.app_registration_rounded, color: _mobileRed),
          SizedBox(height: 10),
          Text(
            'No devices registered yet.',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          SizedBox(height: 4),
          Text(
            'Get the phone Device ID from the mobile Trust Bundle screen, then add it using Register Device.',
            style: TextStyle(color: _mobileMuted),
          ),
        ],
      ),
    );
  }
}

class _DeviceRegistryTile extends StatelessWidget {
  const _DeviceRegistryTile({
    required this.device,
    required this.onApprove,
    required this.onRevoke,
  });

  final RegisteredDevice device;
  final ValueChanged<RegisteredDevice> onApprove;
  final ValueChanged<RegisteredDevice> onRevoke;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _mobileField),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SelectableText(
                device.deviceId,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              _StatusBadge(status: device.status),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            device.ownerName,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            '${device.role.label} - ${device.lastSeenLabel}',
            style: const TextStyle(color: _mobileMuted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (device.status != RegisteredDeviceStatus.approved)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _mobileRed,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => onApprove(device),
                  icon: const Icon(Icons.check_circle_rounded, size: 18),
                  label: const Text('Approve'),
                ),
              if (device.status != RegisteredDeviceStatus.revoked)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _mobileRedDark,
                    side: const BorderSide(color: _mobileRed),
                  ),
                  onPressed: () => _confirmRevoke(context),
                  icon: const Icon(Icons.block_rounded, size: 18),
                  label: const Text('Revoke'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRevoke(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Revoke device?'),
          content: Text(
            '${device.deviceId} will be added to the revoked list in the next trust bundle.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _mobileRed,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Revoke'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      onRevoke(device);
    }
  }
}

class _ValidationMetricsCard extends StatelessWidget {
  const _ValidationMetricsCard();

  @override
  Widget build(BuildContext context) {
    return const _Panel(
      title: 'Validation Metrics',
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
        if (constraints.maxWidth < 960) {
          return Column(children: [left, const SizedBox(height: 22), right]);
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: 22),
            Expanded(child: right),
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
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.13),
            blurRadius: 18,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
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
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _mobileField),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: _mobileRed, size: 30),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(detail, style: const TextStyle(color: _mobileMuted)),
            ],
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
                  style: const TextStyle(fontWeight: FontWeight.w900),
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
                  style: const TextStyle(fontWeight: FontWeight.w900),
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
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final RegisteredDeviceStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      RegisteredDeviceStatus.approved => _mobileRedDark,
      RegisteredDeviceStatus.pending => const Color(0xFF9A5A00),
      RegisteredDeviceStatus.revoked => const Color(0xFF6B6B6B),
    };
    final background = switch (status) {
      RegisteredDeviceStatus.approved => _mobileRed.withValues(alpha: 0.1),
      RegisteredDeviceStatus.pending => const Color(0xFFFFF5E6),
      RegisteredDeviceStatus.revoked => const Color(0xFFEDEDED),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.label.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
