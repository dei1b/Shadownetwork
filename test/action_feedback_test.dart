import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/core/widgets/action_feedback.dart';

void main() {
  testWidgets('clipboard failure never shows a completed state', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'clipboard-unavailable');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  ActionFeedback.copy(context, 'example', message: 'Copied.'),
              child: const Text('Copy'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(find.text('Action failed'), findsOneWidget);
    expect(find.text('Completed'), findsNothing);
    expect(find.text('Copied.'), findsNothing);
  });

  Future<void> mount(
    WidgetTester tester, {
    double width = 400,
    double scale = 1,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => ActionFeedback.show(
                    context,
                    'Your information was saved on this phone.',
                    kind: FeedbackKind.success,
                  ),
                  child: const Text('Save'),
                ),
                TextButton(
                  onPressed: () => ActionFeedback.show(
                    context,
                    'Unable to save. Your entries are still here; check available storage and try again.',
                    kind: FeedbackKind.error,
                  ),
                  child: const Text('Fail'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('success is announced, replaces errors and can be dismissed', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('Fail'));
    await tester.pumpAndSettle();
    expect(find.text('Action failed'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Action failed'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('Action failed'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.liveRegion == true,
      ),
      findsWidgets,
    );
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(ActionStatus), findsNothing);
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets('feedback fits width $width with 200 percent text', (
      tester,
    ) async {
      await mount(tester, width: width, scale: 2);
      await tester.tap(find.text('Fail'));
      await tester.pumpAndSettle();
      expect(find.text('Action failed'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.close).hitTestable(), findsOneWidget);
    });
  }

  testWidgets('queued state does not claim recipient delivery', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ActionStatus(
            title: 'Saved on this phone',
            message: 'Queued for relay. Delivery is still pending.',
            kind: FeedbackKind.success,
          ),
        ),
      ),
    );
    expect(find.text('Saved on this phone'), findsOneWidget);
    expect(find.textContaining('Delivery is still pending'), findsOneWidget);
  });
}
