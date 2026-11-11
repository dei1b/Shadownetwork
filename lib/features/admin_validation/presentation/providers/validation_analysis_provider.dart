import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/validation_analysis.dart';
import 'validation_import_provider.dart';

ValidationAnalysisInput _decode(String source) =>
    const ValidationAnalysisDecoder().decode(source);

final _datasetAnalysisProvider = FutureProvider.autoDispose
    .family<ValidationAnalysisInput, String>((ref, id) async {
      final repository = ref.watch(validationImportRepositoryProvider);
      final source = await repository.readSource(id);
      if (source == null) throw const FormatException();
      return compute(_decode, source);
    });

final validationAnalysisProvider =
    FutureProvider.autoDispose<List<ValidationAnalysisInput>>((ref) async {
      final datasets = ref.watch(
        validationImportControllerProvider.select(
          (state) => state.valueOrNull?.datasets,
        ),
      );
      final results = <ValidationAnalysisInput>[];
      for (final dataset in datasets ?? []) {
        if (dataset.isLegacy) {
          results.add(
            const ValidationAnalysisInput([], [
              'Legacy import excluded from correlated analysis.',
            ]),
          );
          continue;
        }
        try {
          results.add(
            await ref.watch(_datasetAnalysisProvider(dataset.id).future),
          );
        } catch (_) {
          results.add(
            const ValidationAnalysisInput([], [
              'An imported dataset could not be analyzed. Re-import its original JSON.',
            ]),
          );
        }
      }
      return results;
    });
