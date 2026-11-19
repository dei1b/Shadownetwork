import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_typography.dart';
import '../../domain/entities/category.dart';

class SosCategoryPicker extends StatelessWidget {
  const SosCategoryPicker({
    super.key,
    required this.selected,
    required this.onChanged,
    this.accent = AppColors.danger,
  });

  final Category? selected;
  final ValueChanged<Category>? onChanged;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final labelStyle = TextStyle(
      fontFamily: AppTypography.fontFamily,
      fontSize: 14,
      height: 1.2,
      color: colors.onSurface,
      fontWeight: FontWeight.w700,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        const padding = 10.0;
        const iconSize = 24.0;
        final labelWidth =
            ((constraints.maxWidth - gap) / 2 - 2 * padding - iconSize - gap)
                .clamp(0.0, double.infinity);
        var labelHeight = 0.0;
        // Size every tile for the longest label, including accessibility text scaling.
        for (final category in Category.sosCategories) {
          final painter = TextPainter(
            text: TextSpan(
              text: category.label,
              style: DefaultTextStyle.of(context).style.merge(labelStyle),
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: labelWidth);
          if (painter.height > labelHeight) labelHeight = painter.height;
          painter.dispose();
        }
        return GridView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: Category.sosCategories.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            mainAxisExtent: (labelHeight + 2 * padding).clamp(
              52.0,
              double.infinity,
            ),
          ),
          itemBuilder: (context, index) {
            final category = Category.sosCategories[index];
            final isSelected = selected == category;
            return Semantics(
              button: true,
              selected: isSelected,
              enabled: onChanged != null,
              child: Material(
                color: isSelected
                    ? Color.alphaBlend(
                        accent.withValues(alpha: 0.08),
                        colors.surface,
                      )
                    : const Color(0xFFF1F1F1),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: isSelected ? accent : colors.outlineVariant,
                    width: isSelected ? 2 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onChanged == null ? null : () => onChanged!(category),
                  child: Padding(
                    padding: const EdgeInsets.all(padding),
                    child: Row(
                      children: [
                        Icon(
                          switch (category) {
                            Category.medical => Icons.local_hospital,
                            Category.fireElectrical ||
                            Category.fireSmoke => Icons.local_fire_department,
                            Category.safetyThreat => Icons.shield_outlined,
                            Category.rescue => Icons.accessibility_new,
                            Category.accidentInjury => Icons.healing,
                            Category.electricalHazard => Icons.bolt,
                            _ => Icons.more_horiz,
                          },
                          color: accent,
                          size: iconSize,
                        ),
                        const SizedBox(width: gap),
                        Expanded(
                          child: Text(category.label, style: labelStyle),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
