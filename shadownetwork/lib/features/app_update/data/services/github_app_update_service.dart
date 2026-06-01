import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/entities/app_update_check.dart';

class GithubAppUpdateService {
  GithubAppUpdateService({http.Client? client}) : _client = client;

  static const String _owner = 'dei1b';
  static const String _repo = 'Shadownetwork';
  static const String _apiVersion = '2022-11-28';

  final http.Client? _client;

  Future<AppUpdateCheck> checkLatestRelease() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = AppUpdateVersion.tryParse(
      packageInfo.version,
      buildNumber: packageInfo.buildNumber,
    );

    final uri = Uri.https(
      'api.github.com',
      '/repos/$_owner/$_repo/releases/latest',
    );
    final client = _client ?? http.Client();

    try {
      final response = await client.get(
        uri,
        headers: const {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': _apiVersion,
          'User-Agent': 'ShadowNetwork-App-Updater',
        },
      );

      if (response.statusCode == 404) {
        return AppUpdateCheck(
          status: AppUpdateStatus.noRelease,
          currentVersion: currentVersion,
          latestVersion: null,
          releaseName: null,
          releaseUrl: null,
          apkDownloadUrl: null,
        );
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('GitHub returned ${response.statusCode}.');
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final releaseName = (body['name'] as String?)?.trim();
      final tagName = (body['tag_name'] as String?)?.trim();
      final releaseUrl = Uri.tryParse((body['html_url'] as String?) ?? '');
      final latestVersion =
          AppUpdateVersion.tryParse(tagName) ??
          AppUpdateVersion.tryParse(releaseName);
      final apkDownloadUrl = _findAndroidApkDownloadUrl(body);

      if (apkDownloadUrl == null) {
        return AppUpdateCheck(
          status: AppUpdateStatus.noAndroidApk,
          currentVersion: currentVersion,
          latestVersion: latestVersion,
          releaseName: releaseName ?? tagName,
          releaseUrl: releaseUrl,
          apkDownloadUrl: null,
        );
      }

      final status = latestVersion == null || currentVersion == null
          ? AppUpdateStatus.latestVersionUnknown
          : latestVersion.compareTo(currentVersion) > 0
          ? AppUpdateStatus.updateAvailable
          : AppUpdateStatus.upToDate;

      return AppUpdateCheck(
        status: status,
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        releaseName: releaseName ?? tagName,
        releaseUrl: releaseUrl,
        apkDownloadUrl: apkDownloadUrl,
      );
    } finally {
      if (_client == null) {
        client.close();
      }
    }
  }

  Future<bool> openDownload(AppUpdateCheck update) async {
    final downloadUrl = update.apkDownloadUrl;
    if (downloadUrl == null) {
      return false;
    }

    return launchUrl(downloadUrl, mode: LaunchMode.externalApplication);
  }

  Uri? _findAndroidApkDownloadUrl(Map<String, dynamic> release) {
    final assets = release['assets'];
    if (assets is! List) {
      return null;
    }

    for (final asset in assets.whereType<Map<String, dynamic>>()) {
      final name = (asset['name'] as String?)?.toLowerCase() ?? '';
      final downloadUrl = asset['browser_download_url'] as String?;
      if (name.endsWith('.apk') && downloadUrl != null) {
        return Uri.tryParse(downloadUrl);
      }
    }

    return null;
  }
}
