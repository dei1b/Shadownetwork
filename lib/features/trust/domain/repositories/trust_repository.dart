import '../entities/device_trust_record.dart';
import '../entities/trust_bundle.dart';

abstract interface class TrustRepository {
  Future<void> replaceFromBundle(TrustBundle bundle);

  Future<DeviceTrustRecord> getDevice(String deviceId);

  Future<List<DeviceTrustRecord>> getDevices();

  Future<TrustBundleMetadata?> getMetadata();

  Future<void> clear();
}
