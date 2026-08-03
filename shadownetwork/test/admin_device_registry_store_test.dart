import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/data/services/admin_device_registry_store.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loads an empty registry when storage is empty', () async {
    final store = AdminDeviceRegistryStore();

    final devices = await store.loadDevices();

    expect(devices, isEmpty);
  });

  test('persists registered devices', () async {
    final store = AdminDeviceRegistryStore();
    final now = DateTime.utc(2026, 6, 1);
    final device = RegisteredDevice(
      deviceId: 'SN-CIVILIAN-999',
      ownerName: 'Test Resident',
      role: RegisteredDeviceRole.civilian,
      status: RegisteredDeviceStatus.pending,
      registeredAt: now,
      updatedAt: now,
      lastSeenLabel: 'New registration',
    );

    await store.saveDevices([device]);
    final devices = await store.loadDevices();

    expect(devices, hasLength(1));
    expect(devices.single.deviceId, 'SN-CIVILIAN-999');
    expect(devices.single.status, RegisteredDeviceStatus.pending);
  });

  test('removes legacy fake sample devices from stored registry', () async {
    final store = AdminDeviceRegistryStore();
    final now = DateTime.utc(2026, 6, 1);
    final realDevice = RegisteredDevice(
      deviceId: 'SN-REAL-001',
      ownerName: 'Actual Test Phone',
      role: RegisteredDeviceRole.responder,
      status: RegisteredDeviceStatus.approved,
      registeredAt: now,
      updatedAt: now,
      lastSeenLabel: 'Ready',
    );
    final fakeDevice = RegisteredDevice(
      deviceId: 'SN-RESPONDER-001',
      ownerName: 'Old Fake Device',
      role: RegisteredDeviceRole.responder,
      status: RegisteredDeviceStatus.approved,
      registeredAt: now,
      updatedAt: now,
      lastSeenLabel: 'Seeded',
    );

    await store.saveDevices([fakeDevice, realDevice]);
    final devices = await store.loadDevices();

    expect(devices, hasLength(1));
    expect(devices.single.deviceId, 'SN-REAL-001');
  });

  test('trust bundle exports approved and revoked devices only', () {
    final store = AdminDeviceRegistryStore();
    final now = DateTime.utc(2026, 6, 1);
    final bundle = store.buildTrustBundleJson([
      RegisteredDevice(
        deviceId: 'SN-APPROVED',
        ownerName: 'Approved Phone',
        role: RegisteredDeviceRole.responder,
        status: RegisteredDeviceStatus.approved,
        registeredAt: now,
        updatedAt: now,
        lastSeenLabel: 'Ready',
      ),
      RegisteredDevice(
        deviceId: 'SN-PENDING',
        ownerName: 'Pending Phone',
        role: RegisteredDeviceRole.civilian,
        status: RegisteredDeviceStatus.pending,
        registeredAt: now,
        updatedAt: now,
        lastSeenLabel: 'Waiting',
      ),
      RegisteredDevice(
        deviceId: 'SN-REVOKED',
        ownerName: 'Lost Phone',
        role: RegisteredDeviceRole.relay,
        status: RegisteredDeviceStatus.revoked,
        registeredAt: now,
        updatedAt: now,
        lastSeenLabel: 'Revoked',
      ),
    ]);

    final decoded = jsonDecode(bundle) as Map<String, Object?>;
    final approved = decoded['approved_devices'] as List<Object?>;
    final revoked = decoded['revoked_devices'] as List<Object?>;

    expect(approved, hasLength(1));
    expect(revoked, hasLength(1));
    expect(jsonEncode(decoded), isNot(contains('SN-PENDING')));
  });
}
