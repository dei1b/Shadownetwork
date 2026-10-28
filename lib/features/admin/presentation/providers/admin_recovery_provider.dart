import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/desktop_admin_registry_repository.dart';

final desktopAdminRegistryProvider =
    FutureProvider<DesktopAdminRegistryRepository>((ref) {
      throw StateError(
        'Provide the Windows administrator registry at startup.',
      );
    });

final adminRecoveryProvider =
    AsyncNotifierProvider<AdminRecoveryController, AdminIdentityStatus>(
      AdminRecoveryController.new,
    );

class AdminRecoveryController extends AsyncNotifier<AdminIdentityStatus> {
  @override
  Future<AdminIdentityStatus> build() async =>
      (await ref.watch(desktopAdminRegistryProvider.future)).identityStatus();

  Future<void> refresh() async {
    state = await AsyncValue.guard(
      () async => (await ref.read(
        desktopAdminRegistryProvider.future,
      )).identityStatus(),
    );
  }

  Future<void> initializeIdentity() async {
    final repository = await ref.read(desktopAdminRegistryProvider.future);
    await repository.initializeIdentity();
    await refresh();
  }

  Future<String> createBackup(String password) async => (await ref.read(
    desktopAdminRegistryProvider.future,
  )).createEncryptedBackup(password);

  Future<void> restoreBackup(String source, String password) async {
    final repository = await ref.read(desktopAdminRegistryProvider.future);
    await repository.restoreEncryptedBackup(source, password);
    await refresh();
  }
}
