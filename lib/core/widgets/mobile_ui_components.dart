import 'package:flutter/material.dart';

import '../constants/mobile_ui_tokens.dart';

enum MobileStatusTone { positive, warning, error, revoked, info }

({Color background, Color border, Color foreground, IconData defaultIcon})
mobileStatusColors(MobileStatusTone tone) => switch (tone) {
  MobileStatusTone.positive => (
    background: MobileUiTokens.positiveBg,
    border: MobileUiTokens.positiveBorder,
    foreground: MobileUiTokens.positiveFg,
    defaultIcon: Icons.check_circle_outline_rounded,
  ),
  MobileStatusTone.warning => (
    background: MobileUiTokens.warningBg,
    border: MobileUiTokens.warningBorder,
    foreground: MobileUiTokens.warningFg,
    defaultIcon: Icons.info_outline_rounded,
  ),
  MobileStatusTone.error => (
    background: MobileUiTokens.errorBg,
    border: MobileUiTokens.errorBorder,
    foreground: MobileUiTokens.errorFg,
    defaultIcon: Icons.error_outline_rounded,
  ),
  MobileStatusTone.revoked => (
    background: MobileUiTokens.revokedBg,
    border: MobileUiTokens.revokedBorder,
    foreground: MobileUiTokens.revokedFg,
    defaultIcon: Icons.block_rounded,
  ),
  MobileStatusTone.info => (
    background: MobileUiTokens.infoBg,
    border: MobileUiTokens.infoBorder,
    foreground: MobileUiTokens.infoFg,
    defaultIcon: Icons.info_outline_rounded,
  ),
};

class MobileSectionCard extends StatelessWidget {
  const MobileSectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.backgroundColor = MobileUiTokens.cardSurface,
    this.borderColor = MobileUiTokens.border,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color backgroundColor;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(MobileUiTokens.cardRadius),
        border: Border.all(color: borderColor),
        boxShadow: MobileUiTokens.cardShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(MobileUiTokens.cardRadius - 1),
        child: Material(
          type: MaterialType.transparency,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class MobileSectionLabel extends StatelessWidget {
  const MobileSectionLabel(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.only(left: 2, bottom: 8),
  });

  final String text;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Semantics(
        header: true,
        child: Text(text.toUpperCase(), style: MobileUiTokens.eyebrow),
      ),
    );
  }
}

class MobileStatusBadge extends StatelessWidget {
  const MobileStatusBadge({
    super.key,
    required this.label,
    required this.tone,
    this.icon,
  });

  final String label;
  final MobileStatusTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final palette = mobileStatusColors(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(MobileUiTokens.pillRadius),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            ExcludeSemantics(
              child: Icon(icon, size: 14, color: palette.foreground),
            ),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label,
              style: MobileUiTokens.badgeText.copyWith(
                color: palette.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MobileStatusBanner extends StatelessWidget {
  const MobileStatusBanner({
    super.key,
    required this.message,
    this.title,
    this.tone = MobileStatusTone.info,
    this.icon,
    this.liveRegion = false,
  });

  final String message;
  final String? title;
  final MobileStatusTone tone;
  final IconData? icon;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final palette = mobileStatusColors(tone);
    final content = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(MobileUiTokens.controlRadius),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: ExcludeSemantics(
              child: Icon(
                icon ?? palette.defaultIcon,
                size: 20,
                color: palette.foreground,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title case final title?) ...[
                  Text(
                    title,
                    style: MobileUiTokens.bodyStrong.copyWith(
                      fontSize: 14,
                      color: palette.foreground,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  message,
                  style: MobileUiTokens.subtitle.copyWith(
                    fontSize: 13.5,
                    color: palette.foreground,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return liveRegion ? Semantics(liveRegion: true, child: content) : content;
  }
}

class MobileActionTile extends StatelessWidget {
  const MobileActionTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.iconColor = MobileUiTokens.brandRed,
    this.iconBackground = MobileUiTokens.redTint,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color iconColor;
  final Color iconBackground;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Opacity(
          opacity: disabled ? 0.55 : 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: padding,
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: iconBackground,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: ExcludeSemantics(
                      child: Icon(icon, size: 20, color: iconColor),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title, style: MobileUiTokens.bodyStrong),
                        if (subtitle case final subtitle?) ...[
                          const SizedBox(height: 2),
                          Text(subtitle, style: MobileUiTokens.subtitle),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  trailing ??
                      const ExcludeSemantics(
                        child: Icon(
                          Icons.chevron_right_rounded,
                          size: 22,
                          color: MobileUiTokens.mutedInk,
                        ),
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MobileTileDivider extends StatelessWidget {
  const MobileTileDivider({super.key, this.indent = 0});

  final double indent;

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    indent: indent,
    color: MobileUiTokens.subtleDivider,
  );
}

abstract final class MobileButtonStyles {
  static final RoundedRectangleBorder _shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(MobileUiTokens.controlRadius),
  );

  static ButtonStyle get primaryFilled => FilledButton.styleFrom(
    backgroundColor: MobileUiTokens.brandRed,
    foregroundColor: Colors.white,
    disabledBackgroundColor: MobileUiTokens.border,
    disabledForegroundColor: MobileUiTokens.mutedInk,
    minimumSize: const Size(48, 50),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
    shape: _shape,
    textStyle: const TextStyle(
      fontFamily: MobileUiTokens.fontFamily,
      fontSize: 15,
      fontWeight: FontWeight.w700,
    ),
  );

  static ButtonStyle get darkFilled => FilledButton.styleFrom(
    backgroundColor: MobileUiTokens.deepRed,
    foregroundColor: Colors.white,
    disabledBackgroundColor: MobileUiTokens.border,
    disabledForegroundColor: MobileUiTokens.mutedInk,
    minimumSize: const Size(48, 50),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
    shape: _shape,
    textStyle: const TextStyle(
      fontFamily: MobileUiTokens.fontFamily,
      fontSize: 15,
      fontWeight: FontWeight.w700,
    ),
  );

  static ButtonStyle get secondaryOutlined => OutlinedButton.styleFrom(
    foregroundColor: MobileUiTokens.ink,
    disabledForegroundColor: MobileUiTokens.mutedInk,
    side: const BorderSide(color: MobileUiTokens.border),
    backgroundColor: Colors.white,
    minimumSize: const Size(48, 48),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    shape: _shape,
    textStyle: const TextStyle(
      fontFamily: MobileUiTokens.fontFamily,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
  );

  static ButtonStyle get redText => TextButton.styleFrom(
    foregroundColor: MobileUiTokens.brandRed,
    disabledForegroundColor: MobileUiTokens.mutedInk,
    minimumSize: const Size(48, 48),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    shape: _shape,
    textStyle: const TextStyle(
      fontFamily: MobileUiTokens.fontFamily,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
  );
}

abstract final class MobileInputStyles {
  static InputDecoration decoration({
    String? labelText,
    String? hintText,
    String? helperText,
    String? errorText,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    final radius = BorderRadius.circular(MobileUiTokens.controlRadius);
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      helperText: helperText,
      errorText: errorText,
      errorMaxLines: 2,
      helperMaxLines: 2,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      labelStyle: const TextStyle(
        fontFamily: MobileUiTokens.fontFamily,
        color: MobileUiTokens.mutedInk,
        fontSize: 15,
      ),
      floatingLabelStyle: const TextStyle(
        fontFamily: MobileUiTokens.fontFamily,
        color: MobileUiTokens.brandRed,
        fontWeight: FontWeight.w600,
      ),
      hintStyle: const TextStyle(
        fontFamily: MobileUiTokens.fontFamily,
        color: MobileUiTokens.mutedInk,
        fontSize: 14,
      ),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: MobileUiTokens.inputBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: MobileUiTokens.inputBorder),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: MobileUiTokens.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: MobileUiTokens.brandRed, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: MobileUiTokens.errorFg),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: MobileUiTokens.errorFg, width: 2),
      ),
    );
  }
}

/// Consistent white AppBar with crisp bottom border matching mobile screens.
PreferredSizeWidget buildMobileAppBar({
  required String title,
  List<Widget>? actions,
}) => AppBar(
  title: Text(
    title,
    style: const TextStyle(
      fontFamily: MobileUiTokens.fontFamily,
      fontSize: 19,
      fontWeight: FontWeight.w700,
      color: MobileUiTokens.ink,
    ),
  ),
  backgroundColor: MobileUiTokens.canvas,
  foregroundColor: MobileUiTokens.ink,
  surfaceTintColor: Colors.transparent,
  elevation: 0,
  scrolledUnderElevation: 0,
  actions: actions,
  bottom: const PreferredSize(
    preferredSize: Size.fromHeight(1),
    child: Divider(height: 1, thickness: 1, color: MobileUiTokens.subtleDivider),
  ),
);
