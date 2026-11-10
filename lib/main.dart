import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/data/first_run_guide_store.dart';
import 'features/messaging/presentation/providers/local_messaging_providers.dart';
import 'features/messaging/presentation/providers/relay_runtime_provider.dart';
import 'features/validation/presentation/providers/validation_session_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();
  final isMobile =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  final firstRunGuide = isMobile
      ? FirstRunGuideStore.shouldShow(
          container.read(deviceIdentityStoreProvider),
        )
      : null;
  final initialization = _initializeApp(container, firstRunGuide);
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: DisasterCommApp(
        initialization: initialization,
        firstRunGuide: firstRunGuide,
      ),
    ),
  );
}

Future<void> _initializeApp(
  ProviderContainer container,
  Future<bool>? firstRunGuide,
) async {
  try {
    await Firebase.initializeApp();
  } catch (error) {
    debugPrint('Firebase init warning: $error');
  }

  // On a fresh install, AppShellPage starts the relay after the guide so
  // Android permission dialogs don't interrupt the introduction.
  if (await firstRunGuide != true) {
    unawaited(
      container.read(relayRuntimeProvider.notifier).start().catchError((
        Object error,
      ) {
        debugPrint('Relay startup warning: $error');
      }),
    );
  }
  unawaited(
    container
        .read(validationSessionProvider.future)
        .then((_) async {
          await container
              .read(validationSessionProvider.notifier)
              .recordRuntimeMode('background');
        })
        .catchError((Object error) {
          debugPrint('Validation recovery warning: $error');
        }),
  );
}
