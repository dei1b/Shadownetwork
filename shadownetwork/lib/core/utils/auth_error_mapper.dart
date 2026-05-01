String mapAuthError(Object error) {
  final raw = error.toString();

  if (raw.contains('google-services.json')) {
    return 'Firebase is not configured for Android yet. Add google-services.json and rebuild.';
  }

  if (raw.contains('duplicate-app')) {
    return 'Firebase app is already initialized.';
  }

  if (raw.contains('network-request-failed')) {
    return 'Network request failed. Check internet and try again.';
  }

  return raw.replaceFirst('Exception: ', '');
}
