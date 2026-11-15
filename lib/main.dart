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

Future<void> main(List<String> args) async {
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
  final initialization = _initializeApp(
    container,
    firstRunGuide,
    resumeRelay: isMobile && args.contains('--resume-relay'),
  );
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
  Future<bool>? firstRunGuide, {
  required bool resumeRelay,
}) async {
  unawaited(_startRelay(container, firstRunGuide, resumeRelay: resumeRelay));
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

  try {
    await Firebase.initializeApp();
  } catch (error) {
    debugPrint('Firebase init warning: $error');
  }
}

Future<void> _startRelay(
  ProviderContainer container,
  Future<bool>? firstRunGuide, {
  required bool resumeRelay,
}) async {
  try {
    // A normal first launch waits until the guide finishes before requesting
    // permissions. A restored service already has permission to run.
    if (resumeRelay || await firstRunGuide != true) {
      await container.read(relayRuntimeProvider.notifier).start();
    }
  } catch (error) {
    debugPrint('Relay startup warning: $error');
  }
}
