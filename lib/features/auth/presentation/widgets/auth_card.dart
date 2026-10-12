import 'package:flutter/material.dart';

import '../theme/auth_tokens.dart';

class AuthCard extends StatelessWidget {
  const AuthCard({super.key, required this.child, required this.height});

  final Widget child;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AuthTokens.cardRadius),
        boxShadow: const [
          BoxShadow(
            color: Color.fromRGBO(0, 0, 0, 0.25),
            blurRadius: AuthTokens.shadowBlur,
            spreadRadius: AuthTokens.shadowSpread,
            offset: Offset(-0.892, 8.032),
          ),
        ],
      ),
      child: child,
    );
  }
}
