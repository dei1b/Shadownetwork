/// The original local file is kept for reproducibility, never rendered as a preview.
class ValidationImportFile {
  const ValidationImportFile({required this.name, required this.source});
  final String name;
  final String source;
}

enum ValidationImportStatus { valid, duplicate, error, conflict }

class ValidationImportedDataset {
  const ValidationImportedDataset({
    required this.id,
    required this.filename,
    required this.schemaVersion,
    required this.runId,
    required this.sessionId,
    required this.deviceId,
    required this.role,
    required this.exportedAt,
    required this.eventCount,
    required this.receiptCount,
    required this.discoveryCount,
    required this.batteryCount,
    this.importedAt,
  });
  final String id;
  final String filename;
  final int schemaVersion;
  final String? runId;
  final String sessionId;
  final String deviceId;
  final String role;
  final DateTime? exportedAt;
  final DateTime? importedAt;
  final int eventCount;
  final int receiptCount;
  final int discoveryCount;
  final int batteryCount;
  bool get isLegacy => schemaVersion == 1;
  int get recordCount =>
      eventCount + receiptCount + discoveryCount + batteryCount;
}

class ValidationImportEntry {
  const ValidationImportEntry({
    required this.file,
    required this.status,
    this.dataset,
    this.error,
  });
  final ValidationImportFile file;
  final ValidationImportStatus status;
  final ValidationImportedDataset? dataset;
  final String? error;
}

class ValidationImportPreview {
  ValidationImportPreview(Iterable<ValidationImportEntry> entries)
    : entries = List.unmodifiable(entries);
  final List<ValidationImportEntry> entries;
  bool get hasConflicts =>
      entries.any((e) => e.status == ValidationImportStatus.conflict);
  int get validCount =>
      entries.where((e) => e.status == ValidationImportStatus.valid).length;
}

class ValidationImportCommitResult {
  const ValidationImportCommitResult({
    required this.importedCount,
    required this.duplicateCount,
    required this.errorCount,
  });
  final int importedCount;
  final int duplicateCount;
  final int errorCount;
}

class ValidationImportConflict implements Exception {
  const ValidationImportConflict();
  @override
  String toString() =>
      'Conflicting dataset IDs. Nothing was imported. Choose consistent original files and preview again.';
}

abstract interface class ValidationImportRepository {
  Future<ValidationImportPreview> preview(List<ValidationImportFile> files);
  Future<ValidationImportCommitResult> commit(ValidationImportPreview preview);
  Future<List<ValidationImportedDataset>> listDatasets();
  Future<String?> readSource(String id);
  Future<void> remove(String id);
}
