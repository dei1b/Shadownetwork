import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/desktop_file_dialogs.dart';
import '../../../admin_validation/presentation/desktop_validation_import_panel.dart';
import '../../../admin_validation/presentation/providers/validation_import_provider.dart';
import '../providers/admin_recovery_provider.dart';
import '../widgets/admin_recovery_panel.dart';
import 'browser_admin_dashboard_page.dart';

class DesktopAdminShell extends ConsumerStatefulWidget {
  const DesktopAdminShell({super.key});
  @override
  ConsumerState<DesktopAdminShell> createState() => _DesktopAdminShellState();
}

class _DesktopAdminShellState extends ConsumerState<DesktopAdminShell> {
  int _selected = 0;
  final _files = DesktopFileDialogs();
  void _select(int index) {
    setState(() => _selected = index);
    if (index == 2) ref.read(adminRecoveryProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(desktopAdminRegistryProvider);
    final identity = ref.watch(adminRecoveryProvider);
    // Keep imported counts alive while navigating between pages.
    final imports = ref.watch(validationImportControllerProvider);
    final content = registry.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const Center(
        child: Text(
          'Unable to open the administrator registry. Restart the app to retry. Saved data was not reset.',
        ),
      ),
      data: (repository) => switch (_selected) {
        1 => DesktopValidationImportPanel(
          onChooseFiles: _files.chooseValidationFiles,
        ),
        2 => AdminRecoveryPanel(
          onReadBackup: _files.readBackup,
          onSaveBackup: _files.saveBackup,
        ),
        _ => BrowserAdminDashboardPage(
          key: ValueKey(
            '${identity.valueOrNull?.fingerprint}-${identity.valueOrNull?.hasIdentity}',
          ),
          registry: repository,
          desktopMode: true,
          validationPanel: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Validation data',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    imports.when(
                      data: (state) =>
                          '${state.datasets.length} datasets · ${state.datasets.fold<int>(0, (sum, item) => sum + item.recordCount)} records stored on this computer',
                      loading: () => 'Loading imported datasets…',
                      error: (_, _) => 'Unable to load imported datasets.',
                    ),
                  ),
                  const Text(
                    'Import phone exports to review run evidence and data completeness.',
                  ),
                  TextButton(
                    onPressed: () => _select(1),
                    child: const Text('Open validation data'),
                  ),
                ],
              ),
            ),
          ),
        ),
      },
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        return Scaffold(
          appBar: AppBar(title: const Text('Shadow Network Admin')),
          body: Column(
            children: [
              if (_selected != 2 && identity.valueOrNull?.hasIdentity != true)
                Material(
                  color: const Color(0xFFFFF2E3),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Administrator setup or recovery is required before publishing trust bundles.',
                          ),
                        ),
                        TextButton(
                          onPressed: () => _select(2),
                          child: const Text('Open recovery'),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: Row(
                  children: [
                    if (wide) ...[
                      NavigationRail(
                        selectedIndex: _selected,
                        onDestinationSelected: _select,
                        extended: constraints.maxWidth >= 1040,
                        destinations: const [
                          NavigationRailDestination(
                            icon: Icon(Icons.devices_outlined),
                            label: Text('Devices'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.assessment_outlined),
                            label: Text('Validation data'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.backup_outlined),
                            label: Text('Backup & recovery'),
                          ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                    ],
                    Expanded(child: content),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _selected,
                  onDestinationSelected: _select,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.devices_outlined),
                      label: 'Devices',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.assessment_outlined),
                      label: 'Validation data',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.backup_outlined),
                      label: 'Recovery',
                    ),
                  ],
                ),
        );
      },
    );
  }
}
