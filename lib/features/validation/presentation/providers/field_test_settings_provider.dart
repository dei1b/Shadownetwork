import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final fieldTestToolsEnabledProvider =
    AsyncNotifierProvider<FieldTestSettingsController, bool>(
      FieldTestSettingsController.new,
    );

class FieldTestSettingsController extends AsyncNotifier<bool> {
  static const _enabledKey = 'shadow_network_field_test_tools_enabled';

  @override
  Future<bool> build() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_enabledKey) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    if (state.isLoading) return;
    final previous = state;
    state = const AsyncLoading<bool>().copyWithPrevious(previous);
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setBool(_enabledKey, enabled)) {
        throw StateError('Could not save field test settings.');
      }
      state = AsyncData(enabled);
    } catch (_) {
      state = previous;
      rethrow;
    }
  }
}
