import 'package:flutter/material.dart';

/// Desktop and browser administration share the phone app's red identity.
/// Keep this scoped to admin entry points so emergency phone screens are stable.
abstract final class AdminTheme {
  static const pageWidth = 1400.0;
  static const radius = 12.0;
  static const fontFamily = 'Roboto';
  static const pageTitle = TextStyle(
    fontSize: 28,
    height: 1.25,
    fontWeight: FontWeight.w700,
    color: ink,
  );
  static const sectionTitle = TextStyle(
    fontSize: 20,
    height: 1.3,
    fontWeight: FontWeight.w700,
    color: ink,
  );
  static const chartLine = Color(0xFF1565C0);
  static const charging = Color(0xFFE65100);
  static const action = Color(0xFFB52B32);
  static const accent = Color(0xFFE83C3D);
  static const ink = Color(0xFF222222);
  static const muted = Color(0xFF595959);
  static const border = Color(0xFFDDDFE2);
  static const background = Color(0xFFF6F7F8);

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(seedColor: action).copyWith(
      primary: action,
      onPrimary: Colors.white,
      surface: Colors.white,
      onSurface: ink,
      onSurfaceVariant: muted,
      outline: const Color(0xFF777777),
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    return base.copyWith(
      scaffoldBackgroundColor: background,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      textTheme: base.textTheme
          .copyWith(
            headlineMedium: pageTitle,
            headlineSmall: const TextStyle(
              fontSize: 25,
              height: 1.25,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
            titleMedium: const TextStyle(
              fontSize: 16,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: ink,
            ),
            titleSmall: const TextStyle(
              fontSize: 15,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: ink,
            ),
            bodyLarge: const TextStyle(fontSize: 16, height: 1.5, color: ink),
            bodyMedium: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 16,
              height: 1.5,
              color: ink,
            ),
            bodySmall: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 14,
              height: 1.4,
              color: muted,
            ),
            titleLarge: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          )
          .apply(fontFamily: fontFamily),
      dividerTheme: const DividerThemeData(
        color: border,
        thickness: 1,
        space: 1,
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        iconColor: action,
        collapsedIconColor: muted,
        textColor: ink,
        collapsedTextColor: ink,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: Colors.white,
        indicatorColor: Color(0xFFFBE7E8),
        selectedIconTheme: IconThemeData(color: action),
        selectedLabelTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: action,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: muted,
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: Color(0xFFFBE7E8),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: shape,
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: shape,
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: shape,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 16,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: Color(0xFF777777)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: action, width: 2),
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: border),
        ),
      ),
    );
  }
}
