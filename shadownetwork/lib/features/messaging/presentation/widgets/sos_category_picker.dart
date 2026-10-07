import 'package:flutter/material.dart';

import '../../domain/entities/category.dart';

class SosCategoryPicker extends StatelessWidget {
  const SosCategoryPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final Category selected;
  final ValueChanged<Category>? onChanged;

  @override
  Widget build(BuildContext context) {
    const labelStyle = TextStyle(
      fontSize: 12,
      height: 1.2,
      color: Color(0xFFDD3D3D),
      fontWeight: FontWeight.w600,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final labelWidth = (constraints.maxWidth - 10) / 2 - 18.4;
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
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: Category.sosCategories.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 48 + labelHeight,
          ),
          itemBuilder: (context, index) {
            final category = Category.sosCategories[index];
            final isSelected = selected == category;
            return Semantics(
              button: true,
              selected: isSelected,
              child: InkWell(
                onTap: onChanged == null ? null : () => onChanged!(category),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFFFFF5F5)
                        : const Color(0xFFF0EEEF),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFFE83C3D)
                          : Colors.transparent,
                      width: 1.2,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        switch (category) {
                          Category.medical => Icons.local_hospital,
                          Category.fireElectrical =>
                            Icons.local_fire_department,
                          Category.safetyThreat => Icons.shield_outlined,
                          Category.rescue => Icons.accessibility_new,
                          Category.publicHazard => Icons.warning_amber_rounded,
                          _ => Icons.more_horiz,
                        },
                        color: const Color(0xFFE83C3D),
                        size: 22,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        category.label,
                        textAlign: TextAlign.center,
                        style: labelStyle,
                      ),
                    ],
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
