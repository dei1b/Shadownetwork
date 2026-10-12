import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'auth_tokens.dart';

abstract final class AuthTextStyles {
  static TextStyle loginTitle(double scale) => GoogleFonts.squadaOne(
    fontSize: 24.317 * scale,
    color: AuthTokens.text,
    height: 1,
  );

  static TextStyle loginSubtitle(double scale) => GoogleFonts.squadaOne(
    fontSize: 16 * scale,
    color: AuthTokens.label,
    height: 1,
  );

  static TextStyle loginFieldHint(double scale) => GoogleFonts.squadaOne(
    fontSize: 16 * scale,
    color: AuthTokens.label,
    height: 1,
  );

  static TextStyle loginButton(double scale) => GoogleFonts.squadaOne(
    fontSize: 15 * scale,
    color: Colors.white,
    height: 1,
  );

  static TextStyle loginGoogleButton(double scale) => GoogleFonts.squadaOne(
    fontSize: 16 * scale,
    color: Colors.white,
    height: 1,
  );

  static TextStyle loginCta(double scale) => GoogleFonts.squadaOne(
    fontSize: 15 * scale,
    color: AuthTokens.label,
    height: 1.1,
  );

  static TextStyle signupTitle(double scale) => GoogleFonts.squadaOne(
    fontSize: 24.317 * scale,
    color: AuthTokens.text,
    height: 1,
  );

  static TextStyle signupSubtitle(double scale) => GoogleFonts.squadaOne(
    fontSize: 16 * scale,
    color: AuthTokens.label,
    height: 1,
  );

  static TextStyle signupFieldHint(double scale) => GoogleFonts.squadaOne(
    fontSize: 16 * scale,
    color: AuthTokens.label,
    height: 1,
  );

  static TextStyle signupButton(double scale) => GoogleFonts.squadaOne(
    fontSize: 16 * scale,
    color: Colors.white,
    height: 1,
  );

  static TextStyle signupCta(double scale) => GoogleFonts.squadaOne(
    fontSize: 16 * scale,
    color: AuthTokens.label,
    height: 1.1,
  );
}
