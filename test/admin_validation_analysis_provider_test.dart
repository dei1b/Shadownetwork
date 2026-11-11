import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/admin_validation/domain/validation_import.dart';
import 'package:shadownetwork/features/admin_validation/presentation/providers/validation_analysis_provider.dart';
import 'package:shadownetwork/features/admin_validation/presentation/providers/validation_import_provider.dart';
import 'admin_validation_import_repository_test.dart' show importFixture;

class MemoryImports implements ValidationImportRepository {
  final files = <String, String>{};
  final datasets = <ValidationImportedDataset>[];
  @override
  Future<List<ValidationImportedDataset>> listDatasets() async =>
      List.of(datasets);
  @override
  Future<String?> readSource(String id) async => files[id];
  @override
  Future<void> remove(String id) async {
    datasets.removeWhere((d) => d.id == id);
    files.remove(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'sources decode and removal refreshes analysis without restart',
    () async {
      final file = importFixture();
      final json = jsonDecode(file.source) as Map;
      final repo = MemoryImports();
      final id = json['bundle_id'] as String;
      repo.files[id] = file.source;
      repo.datasets.add(
        ValidationImportedDataset(
          id: id,
          filename: 'fixture.json',
          schemaVersion: 2,
          runId: (json['test_run'] as Map)['id'],
          sessionId: (json['session'] as Map)['id'],
          deviceId: (json['device'] as Map)['peer_id'],
          role: 'responder',
          exportedAt: DateTime.utc(2026),
          eventCount: 1,
          receiptCount: 0,
          discoveryCount: 0,
          batteryCount: 0,
        ),
      );
      final container = ProviderContainer(
        overrides: [validationImportRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        validationAnalysisProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      await container.read(validationImportControllerProvider.future);
      expect(
        (await container.read(
          validationAnalysisProvider.future,
        )).single.records,
        isNotEmpty,
      );
      await container
          .read(validationImportControllerProvider.notifier)
          .remove(id);
      expect(await container.read(validationAnalysisProvider.future), isEmpty);
    },
  );
}
