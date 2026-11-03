import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/user_information.dart';

class UserInformationStore {
  static const _key = 'shadow_network_user_information_v1';

  Future<UserInformation?> load() async {
    final source = (await SharedPreferences.getInstance()).getString(_key);
    if (source == null) return null;
    return UserInformation.fromJson(
      Map<String, Object?>.from(jsonDecode(source) as Map),
    );
  }

  Future<void> save(UserInformation information) async {
    final checked = UserInformation.fromJson(information.toJson());
    if (!await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode(checked.toJson()),
    )) {
      throw StateError('Unable to save user information.');
    }
  }
}
