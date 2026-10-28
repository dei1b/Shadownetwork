import '../entities/registered_device.dart';

abstract interface class AdminRegistryRepository {
  Future<List<RegisteredDevice>> loadDevices();
  Future<void> saveDevices(List<RegisteredDevice> devices);
  Future<String> buildTrustBundleJson(List<RegisteredDevice> devices);
}
