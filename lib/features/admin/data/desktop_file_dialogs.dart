import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../../admin_validation/domain/validation_import.dart';
import 'admin_registry_backup.dart';

class DesktopFileDialogs {
  static const _json = XTypeGroup(label: 'JSON files', extensions: ['json']);
  static const _maxBytes = 10 * 1024 * 1024;

  Future<String> _read(XFile file, {int maxBytes = _maxBytes}) async {
    if (await file.length() > maxBytes) {
      throw const FormatException('The file exceeds the permitted size.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxBytes) {
      throw const FormatException('The file exceeds the permitted size.');
    }
    return utf8.decode(bytes);
  }

  Future<List<ValidationImportFile>> chooseValidationFiles() async {
    final files = await openFiles(acceptedTypeGroups: [_json]);
    if (files.length > 50) {
      throw const FormatException('Choose at most 50 files.');
    }
    final result = <ValidationImportFile>[];
    for (final file in files) {
      try {
        result.add(
          ValidationImportFile(name: file.name, source: await _read(file)),
        );
      } catch (_) {
        // Unreadable/oversized files become invalid preview entries. Never echo
        // OS errors or paths, and never read an oversized file into memory.
        result.add(ValidationImportFile(name: file.name, source: ''));
      }
    }
    return result;
  }

  Future<String?> readBackup() async {
    final file = await openFile(acceptedTypeGroups: [_json]);
    return file == null
        ? null
        : _read(file, maxBytes: AdminRegistryBackup.maxSourceBytes);
  }

  Future<bool> saveBackup(String source) async {
    final destination = await getSaveLocation(
      suggestedName: 'shadow-network-admin-backup.json',
      acceptedTypeGroups: [_json],
    );
    if (destination == null) return false;
    await File(destination.path).writeAsString(source, flush: true);
    return true;
  }
}
