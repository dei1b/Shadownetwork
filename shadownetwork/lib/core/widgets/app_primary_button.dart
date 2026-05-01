import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../constants/app_sizes.dart';
import '../constants/app_spacing.dart';

class AppPrimaryButton extends StatelessWidget {
  const AppPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.isLoading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: isLoading ? null : onPressed,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (isLoading)
            const SizedBox(
              width: AppSizes.progressIndicator,
              height: AppSizes.progressIndicator,
              child: CircularProgressIndicator(
                strokeWidth: AppSizes.progressStroke,
                color: AppColors.onPrimary,
              ),
            ),
          if (isLoading) const SizedBox(width: AppSpacing.sm),
          if (!isLoading && icon != null) Icon(icon, size: AppSizes.actionIcon),
          if (!isLoading && icon != null) const SizedBox(width: AppSpacing.sm),
          Text(label),
        ],
      ),
    );
  }
}
