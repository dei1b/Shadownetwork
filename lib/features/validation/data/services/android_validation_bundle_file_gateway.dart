import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/repositories/validation_bundle_file_gateway.dart';

class AndroidValidationBundleFileGateway
    implements ValidationBundleFileGateway {
  AndroidValidationBundleFileGateway({
    Future<Directory> Function()? supportDirectory,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;
  static const _channel = MethodChannel('shadow_network/validation_exports');

  @override
  Future<String> write({
    required String filename,
    required String source,
  }) async {
    if (filename.length > 240 ||
        !RegExp(r'^shadow-network-[A-Za-z0-9_-]+\.json$').hasMatch(filename)) {
      throw ArgumentError('Invalid validation export filename.');
    }
    final support = await _supportDirectory();
    final folder = Directory(p.join(support.path, 'validation_exports'));
    await folder.create(recursive: true);
    final target = File(p.join(folder.path, filename));
    if (await target.exists()) {
      throw const FileSystemException('Export already exists.');
    }
    final temporary = File('${target.path}.tmp');
    try {
      await temporary.writeAsString(source, flush: true);
      await temporary.rename(target.path);
      return target.path;
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  @override
  Future<void> openShareSheet(String path) =>
      _channel.invokeMethod<void>('shareFile', {'path': path});
}
