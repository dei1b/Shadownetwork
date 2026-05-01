import 'package:flutter/material.dart';

class AuthLogo extends StatelessWidget {
  const AuthLogo({super.key, required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/auth/shadownetwork_logo.png',
      width: width,
      height: height,
      fit: BoxFit.cover,
    );
  }
}
