import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/trust_bundle.dart';

class TrustBundleStore {
  static const _bundleKey = 'shadow_network_imported_trust_bundle_v1';

  Future<TrustBundle?> loadBundle() async {
    final preferences = await SharedPreferences.getInstance();
    final rawBundle = preferences.getString(_bundleKey);
    if (rawBundle == null || rawBundle.trim().isEmpty) {
      return null;
    }
    return TrustBundle.fromJsonString(rawBundle);
  }

  Future<TrustBundle> importBundleJson(String source) async {
    final bundle = TrustBundle.fromJsonString(source);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_bundleKey, bundle.toPrettyJson());
    return bundle;
  }

  Future<void> clearBundle() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_bundleKey);
  }
}
