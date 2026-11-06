import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/app/presentation/pages/startup_splash_page.dart';

void main() {
  testWidgets('background engine cannot consume the visible splash duration', (
    tester,
  ) async {
    void background() {
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    void foreground() {
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: StartupGate(
          initialization: Future<void>.value(),
          child: Scaffold(body: TextField(controller: controller)),
        ),
      ),
    );
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/home/startup_splash.png'),
        tester.element(find.byType(StartupSplashPage)),
      ),
    );
    await tester.pumpAndSettle();
    background();
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(StartupSplashPage), findsOneWidget);

    foreground();
    await tester.pumpAndSettle();
    expect(find.byType(StartupSplashPage), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1900));
    expect(find.byType(StartupSplashPage), findsNothing);
    await tester.enterText(find.byType(TextField), 'Keep my screen');

    background();
    await tester.pump(const Duration(seconds: 5));
    foreground();
    await tester.pumpAndSettle();
    expect(find.byType(StartupSplashPage), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    ServicesBinding.instance.channelBuffers.push(
      'shadow_network/app_visibility',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('visible')),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.byType(StartupSplashPage), findsNothing);
    ServicesBinding.instance.channelBuffers.push(
      'shadow_network/app_visibility',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('opened')),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.byType(StartupSplashPage), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1900));
    expect(find.byType(StartupSplashPage), findsNothing);
    expect(controller.text, 'Keep my screen');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
