import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'features/messaging/presentation/providers/relay_runtime_provider.dart';
import 'features/validation/presentation/providers/validation_session_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp();
  } catch (error) {
    debugPrint('Firebase init warning: $error');
  }

  final container = ProviderContainer();
  // Runs without a rendered frame when Android restores the foreground service.
  unawaited(
    container.read(relayRuntimeProvider.notifier).start().catchError((
      Object error,
    ) {
      debugPrint('Relay startup warning: $error');
    }),
  );
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
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const DisasterCommApp(),
    ),
  );
}
