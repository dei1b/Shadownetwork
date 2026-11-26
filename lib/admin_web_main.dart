import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/admin/presentation/theme/admin_theme.dart';
import 'features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'features/registration/data/hosted_publisher_client.dart';
import 'features/registration/data/registration_review_api.dart';

void main() {
  runApp(const ProviderScope(child: ShadowNetworkAdminWebApp()));
}

class ShadowNetworkAdminWebApp extends StatelessWidget {
  const ShadowNetworkAdminWebApp({
    super.key,
    this.reviewApi,
    this.publisherClient,
  });

  final RegistrationReviewApi? reviewApi;
  final HostedPublisherClient? publisherClient;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shadow Network Admin',
      debugShowCheckedModeBanner: false,
      theme: AdminTheme.light,
      home: Scaffold(
        body: SafeArea(
          child: UnifiedRegistrationsWorkspace(
            reviewApi: reviewApi,
            publisherClient: publisherClient ?? HostedPublisherClient.live(),
          ),
        ),
      ),
    );
  }
}
