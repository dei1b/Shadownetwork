import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppTab { home, compose, status }

final appTabProvider = StateProvider<AppTab>((ref) => AppTab.home);
