import 'package:flutter/material.dart';

import '../theme/auth_tokens.dart';

class AuthShell extends StatelessWidget {
  const AuthShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: DecoratedBox(
        decoration: const BoxDecoration(color: AuthTokens.background),
        child: child,
      ),
    );
  }
}
