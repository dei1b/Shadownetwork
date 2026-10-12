import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/auth_tokens.dart';

class AuthBackground extends StatelessWidget {
  const AuthBackground({super.key, required this.child});

  final Widget child;

  static const String _blobPath =
      'M127.628 0.758177C153.832 -4.66644 175.946 20.2063 193.269 37.5178C207.672 51.9121 209.352 71.1251 215.981 89.0557C222.483 106.644 237.586 123.591 231.642 141.316C225.638 159.217 201.683 166.929 185.569 179.739C166.134 195.187 154.441 224.326 127.628 223.997C100.726 223.668 92.4463 191.814 70.9072 178.334C49.8769 165.172 14.6343 166.731 4.02344 146.639C-6.56178 126.594 5.33955 101.602 21.1614 84.1348C34.996 68.8617 65.2779 73.6488 82.002 60.5516C103.157 43.9844 99.4919 6.58271 127.628 0.758177Z';

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: DecoratedBox(
        decoration: const BoxDecoration(color: AuthTokens.background),
        child: Stack(
          children: [
            Positioned(
              left: -93,
              top: -61,
              width: 233,
              height: 224,
              child: Transform.rotate(
                angle: 3.141592653589793,
                child: SvgPicture.string(_blobSvg, fit: BoxFit.fill),
              ),
            ),
            Positioned(
              right: -93,
              bottom: -118,
              width: 233,
              height: 224,
              child: Transform.rotate(
                angle: 3.141592653589793,
                child: SvgPicture.string(_blobSvg, fit: BoxFit.fill),
              ),
            ),
            Positioned.fill(child: child),
          ],
        ),
      ),
    );
  }

  static const String _blobSvg =
      '''
<svg xmlns="http://www.w3.org/2000/svg" width="233" height="224" viewBox="0 0 233 224" fill="none">
  <path d="$_blobPath" fill="#F35555" fill-rule="evenodd" clip-rule="evenodd"/>
</svg>
''';
}
