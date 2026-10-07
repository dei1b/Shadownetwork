import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/presentation/widgets/sos_category_picker.dart';

void main() {
  for (final width in [320.0, 412.0]) {
    testWidgets('SOS categories fit and select at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Category selected = Category.medical;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(26),
                child: StatefulBuilder(
                  builder: (context, setState) {
                    return SosCategoryPicker(
                      selected: selected,
                      onChanged: (category) =>
                          setState(() => selected = category),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(InkWell), findsNWidgets(6));
      for (final label in [
        'Food',
        'Water',
        'Shelter',
        'Transport',
        'Information',
      ]) {
        expect(find.text(label), findsNothing);
      }
      for (final category in Category.sosCategories) {
        await tester.tap(find.text(category.label));
        await tester.pump();
        expect(selected, category);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
