import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('imports and persists a valid trust bundle', () async {
    final store = TrustBundleStore();
    final source = TrustBundle(
      schemaVersion: 1,
      generatedAt: DateTime.utc(2026, 6, 1),
      approvedDevices: [
        TrustedDevice(
          deviceId: 'SN-RESPONDER-010',
          ownerName: 'Responder Phone',
          role: 'responder',
          status: 'approved',
          updatedAt: DateTime.utc(2026, 6, 1),
        ),
      ],
      revokedDevices: [
        TrustedDevice(
          deviceId: 'SN-LOST-001',
          ownerName: 'Lost Phone',
          role: 'civilian',
          status: 'revoked',
          updatedAt: DateTime.utc(2026, 6, 1),
        ),
      ],
    ).toPrettyJson();

    final imported = await store.importBundleJson(source);
    final loaded = await store.loadBundle();

    expect(imported.approvedCount, 1);
    expect(imported.revokedCount, 1);
    expect(loaded?.approvedDevices.single.deviceId, 'SN-RESPONDER-010');
    expect(loaded?.revokedDevices.single.deviceId, 'SN-LOST-001');
  });

  test('rejects unsupported bundle types', () async {
    final store = TrustBundleStore();

    expect(
      () => store.importBundleJson('{"bundle_type":"wrong"}'),
      throwsFormatException,
    );
  });

  test('clears an imported trust bundle', () async {
    final store = TrustBundleStore();
    final source = TrustBundle(
      schemaVersion: 1,
      generatedAt: DateTime.utc(2026, 6, 1),
      approvedDevices: const [],
      revokedDevices: const [],
    ).toPrettyJson();

    await store.importBundleJson(source);
    await store.clearBundle();

    expect(await store.loadBundle(), isNull);
  });
}
