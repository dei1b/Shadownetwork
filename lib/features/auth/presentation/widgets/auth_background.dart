import 'package:flutter/material.dart';

import '../theme/auth_tokens.dart';

class AuthBackground extends StatelessWidget {
  const AuthBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: ColoredBox(color: AuthTokens.background, child: child),
  );
}
