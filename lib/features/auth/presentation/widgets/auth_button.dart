import 'package:flutter/material.dart';

class AuthButton extends StatelessWidget {
  const AuthButton({
    super.key,
    required this.label,
    required this.width,
    required this.height,
    required this.top,
    required this.left,
    required this.scale,
    required this.color,
    required this.radius,
    required this.textStyle,
    this.onPressed,
  });

  final String label;
  final double width;
  final double height;
  final double top;
  final double left;
  final double scale;
  final Color color;
  final double radius;
  final TextStyle Function(double scale) textStyle;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(radius),
          child: Center(
            child: Text(
              label,
              style: textStyle(scale),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
