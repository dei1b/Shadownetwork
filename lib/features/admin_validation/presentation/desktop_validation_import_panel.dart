import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/validation_import.dart';
import 'providers/validation_import_provider.dart';

const _red = Color(0xFFB52B32);
const _darkRed = Color(0xFF861A1A);

class DesktopValidationImportPanel extends ConsumerWidget {
  const DesktopValidationImportPanel({super.key, required this.onChooseFiles});
  final Future<List<ValidationImportFile>> Function() onChooseFiles;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(validationImportControllerProvider)
        .when(
          loading: () => const Center(
            child: CircularProgressIndicator(
              semanticsLabel: 'Loading imported validation datasets',
            ),
          ),
          error: (_, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Unable to load validation data.'),
                TextButton(
                  onPressed: () =>
                      ref.invalidate(validationImportControllerProvider),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
          data: (state) =>
              _ImportContents(state: state, onChooseFiles: onChooseFiles),
        );
  }
}

class _ImportContents extends ConsumerWidget {
  const _ImportContents({required this.state, required this.onChooseFiles});
  final ValidationImportState state;
  final Future<List<ValidationImportFile>> Function() onChooseFiles;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = state.preview;
    final controller = ref.read(validationImportControllerProvider.notifier);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Validation data',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: _darkRed,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Import phone exports for a shared test run. Review each file before saving it to this computer.',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: state.busy
                  ? null
                  : () => controller.chooseFiles(onChooseFiles),
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Choose JSON files'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _red,
                foregroundColor: Colors.white,
              ),
              onPressed:
                  state.busy ||
                      preview == null ||
                      preview.hasConflicts ||
                      preview.validCount == 0
                  ? null
                  : controller.commit,
              icon: const Icon(Icons.download_done),
              label: const Text('Import selected'),
            ),
            const Text('Up to 50 files · 10 MiB per file'),
          ],
        ),
        if (state.busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(
              semanticsLabel: 'Processing validation files',
            ),
          ),
        if (state.error != null) _Notice(text: state.error!, error: true),
        if (state.message != null) _Notice(text: state.message!),
        const SizedBox(height: 16),
        const _Notice(
          text:
              'Data completeness: collect exports from every participating sender, relay and recipient for the same run. Missing files and unsynchronized clocks limit conclusions. Counts below do not establish delivery success, propagation time or wireless performance.',
        ),
        const Text(
          'A schema 2 checksum detects changes; it does not authenticate a phone or approve a device. Original JSON is retained locally for reproducibility. Keep your source files as a separate backup.',
        ),
        if (preview != null) ...[
          const SizedBox(height: 24),
          Text(
            'Selection preview (${preview.entries.length} files)',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Only valid files are imported. Identical duplicates are skipped; invalid files are excluded.',
          ),
          if (preview.hasConflicts)
            const _Notice(
              text:
                  'Conflicting IDs detected. Nothing can be imported from this selection. Choose consistent original files and preview again.',
              error: true,
            ),
          for (var index = 0; index < preview.entries.length; index++)
            _PreviewCard(
              key: ValueKey('preview-$index'),
              entry: preview.entries[index],
            ),
        ],
        const SizedBox(height: 24),
        Text(
          'Imported datasets (${state.datasets.length})',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          '${state.datasets.fold<int>(0, (sum, item) => sum + item.recordCount)} records stored · ${state.datasets.where((item) => item.isLegacy).length} legacy datasets',
        ),
        if (state.datasets.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No validation datasets imported yet. Choose exported JSON files to begin.',
            ),
          ),
        for (final dataset in state.datasets)
          _DatasetCard(
            key: ValueKey(dataset.id),
            dataset: dataset,
            busy: state.busy,
          ),
      ],
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({super.key, required this.entry});
  final ValidationImportEntry entry;

  @override
  Widget build(BuildContext context) => _PanelCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          entry.file.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          switch (entry.status) {
            ValidationImportStatus.valid => 'Valid · ready to import',
            ValidationImportStatus.duplicate => 'Duplicate · skipped',
            ValidationImportStatus.error => 'Error · excluded',
            ValidationImportStatus.conflict => 'Conflict · import blocked',
          },
          style: TextStyle(
            color:
                entry.status == ValidationImportStatus.error ||
                    entry.status == ValidationImportStatus.conflict
                ? _darkRed
                : null,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (entry.dataset != null) _DatasetMetadata(dataset: entry.dataset!),
        if (entry.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(entry.error!),
          ),
      ],
    ),
  );
}

class _DatasetCard extends ConsumerWidget {
  const _DatasetCard({super.key, required this.dataset, required this.busy});
  final ValidationImportedDataset dataset;
  final bool busy;

  Future<void> _confirmRemoval(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove imported dataset?'),
        content: Text(
          'Remove ${dataset.filename} from this computer’s validation database? Your original JSON file is unaffected and can be imported again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await ref
          .read(validationImportControllerProvider.notifier)
          .remove(dataset.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _PanelCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                dataset.filename,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: 'Remove imported dataset',
              onPressed: busy ? null : () => _confirmRemoval(context, ref),
              icon: const Icon(Icons.delete_outline, color: _darkRed),
            ),
          ],
        ),
        _DatasetMetadata(dataset: dataset),
        if (dataset.importedAt != null)
          Text('Imported ${dataset.importedAt!.toUtc().toIso8601String()}'),
      ],
    ),
  );
}

class _DatasetMetadata extends StatelessWidget {
  const _DatasetMetadata({required this.dataset});
  final ValidationImportedDataset dataset;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          dataset.isLegacy
              ? 'Legacy schema 1 · no checksum'
              : 'Schema 2 · checksum verified',
        ),
        if (dataset.isLegacy)
          const Text(
            'Legacy JSON may contain private notes or identifiers. Its privacy and authenticity are unverified. Device/session labels below are pseudonymized for display.',
            style: TextStyle(color: _darkRed),
          ),
        const SizedBox(height: 6),
        Text('Run: ${dataset.runId ?? 'Unavailable (legacy session)'}'),
        Text('Session: ${dataset.sessionId}'),
        Text('Device: ${dataset.deviceId}'),
        Text('Role: ${dataset.role}'),
        Text(
          'Export date: ${dataset.exportedAt?.toUtc().toIso8601String() ?? 'Unavailable in schema 1'}',
        ),
        const SizedBox(height: 6),
        Text(
          '${dataset.recordCount} records · ${dataset.receiptCount} SOS receipts · ${dataset.eventCount} message events · ${dataset.discoveryCount} discovery attempts · ${dataset.batteryCount} battery samples',
        ),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: error ? const Color(0xFFFFEEEE) : const Color(0xFFF6F6F6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: error ? _red : const Color(0xFFE1E1E1)),
      ),
      child: Text(text, style: TextStyle(color: error ? _darkRed : null)),
    ),
  );
}

class _PanelCard extends StatelessWidget {
  const _PanelCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE1E1E1)),
    ),
    child: child,
  );
}
