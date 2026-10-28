import 'package:flutter/material.dart';

import '../../domain/entities/registered_device.dart';

const _mobileRed = Color(0xFFB52B32);
const _mobileRedDark = Color(0xFF861A1A);
const _mobileMuted = Color(0xFF595959);
const _mobileField = Color(0xFFDDDFE2);

/// Local registry review; these records do not indicate live phone connectivity.
class AdminDeviceRegistryPanel extends StatefulWidget {
  const AdminDeviceRegistryPanel({
    super.key,
    this.busy = false,
    required this.devices,
    required this.onApprove,
    required this.onRevoke,
    required this.onEdit,
    required this.onDelete,
  });
  final List<RegisteredDevice> devices;
  final bool busy;
  final ValueChanged<RegisteredDevice> onApprove;
  final ValueChanged<RegisteredDevice> onRevoke;
  final ValueChanged<RegisteredDevice> onEdit;
  final ValueChanged<RegisteredDevice> onDelete;

  @override
  State<AdminDeviceRegistryPanel> createState() =>
      _AdminDeviceRegistryPanelState();
}

class _AdminDeviceRegistryPanelState extends State<AdminDeviceRegistryPanel> {
  final _search = TextEditingController();
  RegisteredDeviceStatus? _status;
  String _role = 'all';
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _clear() => setState(() {
    _search.clear();
    _status = null;
    _role = 'all';
  });

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final devices = widget.devices
        .where(
          (device) =>
              (_status == null || device.status == _status) &&
              (_role == 'all' || device.role.name == _role) &&
              (device.ownerName.toLowerCase().contains(query) ||
                  device.deviceId.toLowerCase().contains(query)),
        )
        .toList();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _mobileField),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Registered users and phones',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Review phone registrations before sharing an updated trust bundle.',
            style: TextStyle(color: _mobileMuted),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final search = TextField(
                key: const ValueKey('admin-device-search'),
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Search devices',
                  hintText: 'Owner name or device ID',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () => setState(_search.clear),
                          icon: const Icon(Icons.close),
                        ),
                ),
              );
              final role = Semantics(
                key: const ValueKey('admin-role-filter'),
                child: DropdownButtonFormField<String>(
                  key: ValueKey(_role),
                  // Recreate the field on reset so FormField state follows the selected role.
                  initialValue: _role,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Filter by role',
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: 'all',
                      child: Text('All roles'),
                    ),
                    for (final role in RegisteredDeviceRole.values)
                      DropdownMenuItem(
                        value: role.name,
                        child: Text(role.label),
                      ),
                  ],
                  onChanged: (value) => setState(() => _role = value ?? 'all'),
                ),
              );
              if (constraints.maxWidth >= 500 &&
                  MediaQuery.textScalerOf(context).scale(1) <= 1.5) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
              FilterChip(
                label: const Text('All statuses'),
                selected: _status == null,
                onSelected: (_) => setState(() => _status = null),
              ),
              for (final status in RegisteredDeviceStatus.values)
                FilterChip(
                  label: Text(status.label),
                  selected: _status == status,
                  onSelected: (selected) =>
                      setState(() => _status = selected ? status : null),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              'Showing ${devices.length} of ${widget.devices.length} devices',
              style: const TextStyle(color: _mobileMuted),
            ),
          ),
          if (query.isNotEmpty || _status != null || _role != 'all')
            TextButton.icon(
              onPressed: _clear,
              icon: const Icon(Icons.filter_alt_off_outlined),
              label: const Text('Clear filters'),
            ),
          const SizedBox(height: 16),
          if (widget.devices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'No devices registered yet. Use the registration form to add a phone.',
              ),
            )
          else if (devices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No devices match your filters.'),
            )
          else
            for (final device in devices)
              _DeviceRegistryTile(
                key: ValueKey(device.deviceId),
                device: device,
                busy: widget.busy,
                onApprove: widget.onApprove,
                onRevoke: widget.onRevoke,
                onEdit: widget.onEdit,
                onDelete: widget.onDelete,
              ),
          const Text(
            'Approval takes effect on phones after they import the updated trust bundle. '
            'These records do not show whether a phone is online.',
            style: TextStyle(color: _mobileMuted, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _DeviceRegistryTile extends StatelessWidget {
  const _DeviceRegistryTile({
    super.key,
    this.busy = false,
    required this.device,
    required this.onApprove,
    required this.onRevoke,
    required this.onEdit,
    required this.onDelete,
  });

  final RegisteredDevice device;
  final bool busy;
  final ValueChanged<RegisteredDevice> onApprove;
  final ValueChanged<RegisteredDevice> onRevoke;
  final ValueChanged<RegisteredDevice> onEdit;
  final ValueChanged<RegisteredDevice> onDelete;

  @override
  Widget build(BuildContext context) {
    final note = device.lastSeenLabel == 'Approved for next sync'
        ? 'Approved locally - share updated trust bundle'
        : device.lastSeenLabel;
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
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
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
            '${device.role.label} - $note',
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
                  onPressed: busy ? null : () => onApprove(device),
                  icon: const Icon(Icons.check_circle_rounded, size: 18),
                  label: const Text('Approve'),
                ),
              if (device.status != RegisteredDeviceStatus.revoked)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _mobileRedDark,
                    side: const BorderSide(color: _mobileRed),
                  ),
                  onPressed: busy ? null : () => _confirmRevoke(context),
                  icon: const Icon(Icons.block_rounded, size: 18),
                  label: const Text('Revoke'),
                ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF333333),
                  side: const BorderSide(color: Color(0xFFBDBDBD)),
                ),
                onPressed: busy ? null : () => onEdit(device),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit'),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: _mobileRedDark),
                onPressed: busy ? null : () => onDelete(device),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Delete'),
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

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final RegisteredDeviceStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      RegisteredDeviceStatus.approved => const Color(0xFF23613D),
      RegisteredDeviceStatus.pending => const Color(0xFF9A5A00),
      RegisteredDeviceStatus.revoked => const Color(0xFF6B6B6B),
    };
    final background = switch (status) {
      RegisteredDeviceStatus.approved => const Color(0xFFEAF6EF),
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
        status.label,
        style: TextStyle(
          color: color,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
