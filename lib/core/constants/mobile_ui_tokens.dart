import 'package:flutter/material.dart';

import 'app_typography.dart';

/// Visual tokens shared across ShadowNetwork's mobile account, profile,
/// settings, and backup registration surfaces.
///
/// Mirrors the red, white, warm neutral, and semantic status language already
/// established on Home, Messages, Maps, Nearby, and Admin screens.
abstract final class MobileUiTokens {
  static const String fontFamily = AppTypography.fontFamily;

  // Brand & action reds
  static const Color brandRed = Color(0xFFCC3032);
  static const Color accentRed = Color(0xFFE83C3D);
  static const Color deepRed = Color(0xFF861A1A);
  static const Color redTint = Color(0xFFFDECEC);
  static const Color redBorder = Color(0xFFF3C6C6);

  // Surfaces & neutrals
  static const Color canvas = Color(0xFFFFFFFF);
  static const Color warmSurface = Color(0xFFFAF7F3);
  static const Color cardSurface = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE4E0DC);
  static const Color subtleDivider = Color(0xFFF0ECE8);
  static const Color inputBorder = Color(0xFFC8C2BC);
  static const Color ink = Color(0xFF1F1F1F);
  static const Color mutedInk = Color(0xFF625A54);

  // Semantic status palettes (matching HomePage._buildDeviceAccessBanner)
  static const Color positiveBg = Color(0xFFEAF6EF);
  static const Color positiveBorder = Color(0xFFC5E4D0);
  static const Color positiveFg = Color(0xFF23613D);

  static const Color warningBg = Color(0xFFFFF1D6);
  static const Color warningBorder = Color(0xFFF0D5A0);
  static const Color warningFg = Color(0xFF7A4B00);

  static const Color errorBg = Color(0xFFFFE4E1);
  static const Color errorBorder = Color(0xFFF2B8B3);
  static const Color errorFg = Color(0xFF8B1E1E);

  static const Color revokedBg = Color(0xFF7D1A1A);
  static const Color revokedBorder = Color(0xFF7D1A1A);
  static const Color revokedFg = Color(0xFFFFFFFF);

  static const Color infoBg = Color(0xFFF2F4F7);
  static const Color infoBorder = Color(0xFFD7DCE2);
  static const Color infoFg = Color(0xFF374151);

  // Geometry
  static const double cardRadius = 16;
  static const double controlRadius = 12;
  static const double pillRadius = 8;
  static const double sheetRadius = 20;

  // Typography styles
  static const TextStyle pageTitle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.2,
    color: ink,
  );

  static const TextStyle sectionHeading = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    fontWeight: FontWeight.w700,
    height: 1.3,
    color: ink,
  );

  static const TextStyle eyebrow = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    height: 1.2,
    letterSpacing: 0.6,
    color: mutedInk,
  );

  static const TextStyle body = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: ink,
  );

  static const TextStyle bodyStrong = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.35,
    color: ink,
  );

  static const TextStyle subtitle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.35,
    color: mutedInk,
  );

  static const TextStyle badgeText = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    height: 1.2,
  );

  static List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.06),
      blurRadius: 14,
      offset: const Offset(0, 3),
    ),
  ];
}
