import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/github_app_update_service.dart';

final appUpdateServiceProvider = Provider<GithubAppUpdateService>((ref) {
  return GithubAppUpdateService();
});
