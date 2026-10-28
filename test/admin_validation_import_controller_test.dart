import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/admin_validation/domain/validation_import.dart';
import 'package:shadownetwork/features/admin_validation/presentation/providers/validation_import_provider.dart';

class _Repository implements ValidationImportRepository {
  bool saved = false;
  bool removed = false;
  @override
  Future<List<ValidationImportedDataset>> listDatasets() async {
    if (saved || removed) throw Exception('synthetic refresh failure');
    return [];
  }

  @override
  Future<ValidationImportPreview> preview(
    List<ValidationImportFile> files,
  ) async => ValidationImportPreview(
    files.map(
      (file) => ValidationImportEntry(
        file: file,
        status: ValidationImportStatus.valid,
      ),
    ),
  );
  @override
  Future<ValidationImportCommitResult> commit(
    ValidationImportPreview preview,
  ) async {
    saved = true;
    return const ValidationImportCommitResult(
      importedCount: 1,
      duplicateCount: 0,
      errorCount: 0,
    );
  }

  @override
  Future<void> remove(String id) async {
    removed = true;
  }

  @override
  Future<String?> readSource(String id) async => null;
}

void main() {
  test(
    'successful import is reported honestly if refreshing the list fails',
    () async {
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [
          validationImportRepositoryProvider.overrideWithValue(repository),
        ],
      );
      final subscription = container.listen(
        validationImportControllerProvider,
        (_, _) {},
      );
      addTearDown(() {
        subscription.close();
        container.dispose();
      });
      await container.read(validationImportControllerProvider.future);
      final controller = container.read(
        validationImportControllerProvider.notifier,
      );
      await controller.chooseFiles(
        () async => [
          const ValidationImportFile(name: 'test.json', source: '{}'),
        ],
      );
      await controller.commit();
      final state = container
          .read(validationImportControllerProvider)
          .requireValue;
      expect(repository.saved, isTrue);
      expect(state.message, contains('saved'));
      expect(state.error, isNot(contains('No partial import')));
      expect(state.busy, isFalse);
    },
  );
  test(
    'successful removal is reported honestly if refreshing the list fails',
    () async {
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [
          validationImportRepositoryProvider.overrideWithValue(repository),
        ],
      );
      final subscription = container.listen(
        validationImportControllerProvider,
        (_, _) {},
      );
      addTearDown(() {
        subscription.close();
        container.dispose();
      });
      await container.read(validationImportControllerProvider.future);
      await container
          .read(validationImportControllerProvider.notifier)
          .remove('test');
      final state = container
          .read(validationImportControllerProvider)
          .requireValue;
      expect(repository.removed, isTrue);
      expect(state.message, contains('removed'));
      expect(state.error, isNot(contains('Unable to remove')));
    },
  );
}
