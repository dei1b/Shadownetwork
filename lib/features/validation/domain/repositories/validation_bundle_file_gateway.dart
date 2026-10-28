abstract interface class ValidationBundleFileGateway {
  Future<String> write({required String filename, required String source});
  Future<void> openShareSheet(String path);
}

/// The export file and its history exist, but the share chooser could not open.
class ValidationBundleShareException implements Exception {
  const ValidationBundleShareException();
}
