import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/validation_import.dart';

final validationImportRepositoryProvider = Provider<ValidationImportRepository>(
  (ref) {
    throw StateError(
      'The desktop validation repository must be provided at startup.',
    );
  },
);

final validationImportControllerProvider =
    AsyncNotifierProvider.autoDispose<
      ValidationImportController,
      ValidationImportState
    >(ValidationImportController.new);

class ValidationImportState {
  const ValidationImportState({
    this.datasets = const [],
    this.preview,
    this.busy = false,
    this.message,
    this.error,
  });
  final List<ValidationImportedDataset> datasets;
  final ValidationImportPreview? preview;
  final bool busy;
  final String? message;
  final String? error;
}

class ValidationImportController
    extends AutoDisposeAsyncNotifier<ValidationImportState> {
  ValidationImportRepository get _repository =>
      ref.read(validationImportRepositoryProvider);
  @override
  Future<ValidationImportState> build() async => ValidationImportState(
    datasets: await ref
        .watch(validationImportRepositoryProvider)
        .listDatasets(),
  );

  Future<void> chooseFiles(
    Future<List<ValidationImportFile>> Function() choose,
  ) async {
    final previous = state.valueOrNull;
    if (previous == null || previous.busy) return;
    state = AsyncData(
      ValidationImportState(
        datasets: previous.datasets,
        preview: previous.preview,
        busy: true,
      ),
    );
    try {
      final files = await choose();
      if (files.isEmpty) {
        state = AsyncData(previous);
        return;
      }
      if (files.length > 50) {
        throw const FormatException('Choose at most 50 files.');
      }
      final preview = await _repository.preview(files);
      state = AsyncData(
        ValidationImportState(datasets: previous.datasets, preview: preview),
      );
    } catch (_) {
      state = AsyncData(
        ValidationImportState(
          datasets: previous.datasets,
          preview: previous.preview,
          error:
              'Unable to open this selection. Choose up to 50 UTF-8 JSON files, each at most 10 MiB.',
        ),
      );
    }
  }

  Future<void> commit() async {
    final previous = state.valueOrNull;
    final preview = previous?.preview;
    if (previous == null ||
        previous.busy ||
        preview == null ||
        preview.hasConflicts ||
        preview.validCount == 0) {
      return;
    }
    state = AsyncData(
      ValidationImportState(
        datasets: previous.datasets,
        preview: preview,
        busy: true,
      ),
    );
    late final ValidationImportCommitResult result;
    try {
      result = await _repository.commit(preview);
    } on ValidationImportConflict catch (_) {
      state = AsyncData(
        ValidationImportState(
          datasets: previous.datasets,
          error: const ValidationImportConflict().toString(),
        ),
      );
      return;
    } catch (_) {
      state = AsyncData(
        ValidationImportState(
          datasets: previous.datasets,
          preview: preview,
          error:
              'Unable to save the selection. No partial import was kept. Check available storage and try again.',
        ),
      );
      return;
    }
    try {
      state = AsyncData(
        ValidationImportState(
          datasets: await _repository.listDatasets(),
          preview: await _repository.preview(
            preview.entries.map((e) => e.file).toList(),
          ),
          message:
              'Imported ${result.importedCount}; skipped ${result.duplicateCount} duplicates; excluded ${result.errorCount} invalid files.',
        ),
      );
    } catch (_) {
      state = AsyncData(
        ValidationImportState(
          datasets: previous.datasets,
          message:
              'Import saved (${result.importedCount} datasets). The list could not be refreshed. Reopen Validation data or restart the app to reload.',
        ),
      );
    }
  }

  Future<void> remove(String id) async {
    final previous = state.valueOrNull;
    if (previous == null || previous.busy) return;
    state = AsyncData(
      ValidationImportState(
        datasets: previous.datasets,
        preview: previous.preview,
        busy: true,
      ),
    );
    try {
      await _repository.remove(id);
    } catch (_) {
      state = AsyncData(
        ValidationImportState(
          datasets: previous.datasets,
          preview: previous.preview,
          error: 'Unable to remove this dataset. Try again.',
        ),
      );
      return;
    }
    try {
      final preview = previous.preview;
      state = AsyncData(
        ValidationImportState(
          datasets: await _repository.listDatasets(),
          preview: preview == null
              ? null
              : await _repository.preview(
                  preview.entries.map((e) => e.file).toList(),
                ),
          message:
              'Imported dataset removed. You can import the original JSON again.',
        ),
      );
    } catch (_) {
      state = AsyncData(
        ValidationImportState(
          datasets: previous.datasets.where((item) => item.id != id).toList(),
          message:
              'Imported dataset removed. The list could not be refreshed. Restart the app to reload.',
        ),
      );
    }
  }
}
