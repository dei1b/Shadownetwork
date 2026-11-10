import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/security/data/services/device_identity_store.dart';

abstract final class FirstRunGuideStore {
  static const _completeKey = 'shadow_network_first_run_guide_complete';

  static Future<bool> shouldShow(DeviceIdentityStore identity) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final complete = preferences.getBool(_completeKey);
      if (complete != null) return !complete;

      // Save the initial decision before relay startup can create an identity.
      final existingDevice = await identity.hasStoredIdentity();
      await preferences.setBool(_completeKey, existingDevice);
      return !existingDevice;
    } catch (error) {
      debugPrint('First-run guide check failed: $error');
      return false;
    }
  }

  static Future<void> complete() async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(_completeKey, true)) {
      throw StateError('Could not save first-run guide completion.');
    }
  }
}
