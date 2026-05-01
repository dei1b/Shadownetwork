import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class AuthEyeIcon extends StatelessWidget {
  const AuthEyeIcon({super.key});

  static const String _strokeColor = '#838181';
  static const double _strokeWidth = 1.30769;

  static const String _svg =
      '''
<svg xmlns="http://www.w3.org/2000/svg" width="18.3077" height="15.6925" viewBox="0 0 18.3077 15.6925" fill="none">
  <g>
    <path d="M9.1537 3.00753C3.58346 3.00753 1.2448 8.92079 1.2448 9.02309C1.2448 9.1254 3.58346 15.0386 9.1537 15.0386C14.724 15.0386 17.0626 9.1254 17.0626 9.02309C17.0626 8.92079 14.724 3.00753 9.1537 3.00753Z" stroke="$_strokeColor" stroke-width="$_strokeWidth" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M3.00652 6.09156L0.653847 3.81111" stroke="$_strokeColor" stroke-width="$_strokeWidth" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M6.70111 3.41626L5.82747 0.654022" stroke="$_strokeColor" stroke-width="$_strokeWidth" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M11.6118 3.41627L12.4803 0.654022" stroke="$_strokeColor" stroke-width="$_strokeWidth" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M15.3376 6.13248L17.6538 3.81111" stroke="$_strokeColor" stroke-width="$_strokeWidth" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M6.87584 9.02328C6.87584 9.32243 6.93476 9.61865 7.04924 9.89503C7.16372 10.1714 7.33152 10.4225 7.54305 10.6341C7.75458 10.8456 8.00571 11.0134 8.28209 11.1279C8.55847 11.2424 8.85469 11.3013 9.15384 11.3013C9.45299 11.3013 9.74921 11.2424 10.0256 11.1279C10.302 11.0134 10.5531 10.8456 10.7646 10.6341C10.9762 10.4225 11.144 10.1714 11.2584 9.89503C11.3729 9.61865 11.4318 9.32243 11.4318 9.02328C11.4318 8.72413 11.3729 8.42791 11.2584 8.15153C11.144 7.87515 10.9762 7.62402 10.7646 7.41249C10.5531 7.20096 10.302 7.03316 10.0256 6.91868C9.74921 6.8042 9.45299 6.74528 9.15384 6.74528C8.85469 6.74528 8.55847 6.8042 8.28209 6.91868C8.00571 7.03316 7.75458 7.20096 7.54305 7.41249C7.33152 7.62402 7.16372 7.87515 7.04924 8.15153C6.93476 8.42791 6.87584 8.72413 6.87584 9.02328Z" stroke="$_strokeColor" stroke-width="$_strokeWidth"/>
  </g>
</svg>
''';

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(_svg);
  }
}
