import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/app/presentation/pages/startup_splash_page.dart';
import 'package:shadownetwork/core/widgets/native_activity_scope.dart';

void main() {
  testWidgets('startup action is tappable on the frame after readiness', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _cacheSplashArtwork(tester);
    final initialization = Completer<void>();
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StartupGate(
          initialization: initialization.future,
          child: Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => taps++,
                child: const Text('Send SOS'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final splash = find.byType(StartupSplashPage);
    final sendSos = find.widgetWithText(ElevatedButton, 'Send SOS');
    expect(splash, findsOneWidget);
    expect(sendSos, findsNothing);

    initialization.complete();
    await tester.idle();
    await tester.pump();
    expect(splash, findsOneWidget);
    expect(sendSos.hitTestable(), findsNothing);

    await tester.pump();
    expect(splash, findsNothing);
    await tester.tap(sendSos);
    expect(taps, 1);
  });

  testWidgets('background startup waits for a visible frame', (tester) async {
    await _cacheSplashArtwork(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpWidget(
      MaterialApp(
        home: StartupGate(
          initialization: Future<void>.value(),
          child: const Scaffold(body: Text('Home')),
        ),
      ),
    );

    final splash = find.byType(StartupSplashPage);
    await tester.pump(const Duration(seconds: 5));
    expect(splash, findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(splash, findsOneWidget);

    await _sendActivityEvent('visible');
    await tester.pump();
    expect(splash, findsOneWidget);
    await tester.pump();
    expect(splash, findsNothing);
  });

  testWidgets('retained engine preserves UI state across activity events', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _cacheSplashArtwork(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: StartupGate(
          initialization: Future<void>.value(),
          child: const Scaffold(body: TextField()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final splash = find.byType(StartupSplashPage);
    final activityScope = find.byType(NativeActivityScope);
    expect(splash, findsNothing);
    expect(tester.widget<NativeActivityScope>(activityScope).generation, 0);
    await tester.enterText(find.byType(TextField), 'Keep my screen');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _sendActivityEvent('visible');
    await tester.pumpAndSettle();
    expect(splash, findsNothing);
    expect(tester.widget<NativeActivityScope>(activityScope).generation, 0);

    await _sendActivityEvent('reattached');
    await tester.pumpAndSettle();
    expect(splash, findsNothing);
    expect(tester.widget<NativeActivityScope>(activityScope).generation, 1);

    await _sendActivityEvent('opened');
    await tester.pump();
    expect(splash, findsOneWidget);
    expect(tester.widget<NativeActivityScope>(activityScope).generation, 2);
    await tester.pump(const Duration(seconds: 2));
    expect(splash, findsOneWidget);

    await _sendActivityEvent('visible');
    await tester.pump();
    expect(splash, findsOneWidget);
    await tester.pump();
    expect(splash, findsNothing);
    expect(find.text('Keep my screen'), findsOneWidget);
  });
}

Future<void> _cacheSplashArtwork(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: Scaffold()));
  await tester.runAsync(
    () => precacheImage(
      const AssetImage('assets/home/startup_splash.png'),
      tester.element(find.byType(Scaffold)),
    ),
  );
}

Future<void> _sendActivityEvent(String method) async {
  final handled = Completer<void>();
  ServicesBinding.instance.channelBuffers.push(
    'shadow_network/app_visibility',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
    (_) => handled.complete(),
  );
  await handled.future;
}
