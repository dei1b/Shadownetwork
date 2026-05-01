import 'package:flutter/material.dart';

import '../theme/auth_tokens.dart';
import '../theme/auth_text_styles.dart';
import 'auth_eye_icon.dart';

class AuthField extends StatelessWidget {
  const AuthField({
    super.key,
    required this.hintText,
    required this.width,
    required this.height,
    required this.top,
    required this.left,
    required this.scale,
    this.obscureText = false,
    this.showEyeIcon = false,
    this.controller,
  });

  final String hintText;
  final double width;
  final double height;
  final double top;
  final double left;
  final double scale;
  final bool obscureText;
  final bool showEyeIcon;
  final TextEditingController? controller;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: AuthTokens.fieldFill,
          borderRadius: BorderRadius.circular(AuthTokens.fieldRadius),
        ),
        alignment: Alignment.center,
        child: TextField(
          controller: controller,
          obscureText: obscureText,
          style: AuthTextStyles.loginFieldHint(
            scale,
          ).copyWith(color: AuthTokens.text),
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: hintText,
            hintStyle: AuthTextStyles.loginFieldHint(scale),
            contentPadding: EdgeInsets.symmetric(
              horizontal: 16 * scale,
              vertical: 11 * scale,
            ),
            suffixIcon: showEyeIcon
                ? const Padding(
                    padding: EdgeInsets.only(right: 10),
                    child: AuthEyeIcon(),
                  )
                : null,
            suffixIconConstraints: const BoxConstraints(
              minWidth: 0,
              minHeight: 0,
            ),
          ),
        ),
      ),
    );
  }
}
