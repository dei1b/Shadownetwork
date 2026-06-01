class AppUpdateCheck {
  const AppUpdateCheck({
    required this.status,
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseName,
    required this.releaseUrl,
    required this.apkDownloadUrl,
  });

  final AppUpdateStatus status;
  final AppUpdateVersion? currentVersion;
  final AppUpdateVersion? latestVersion;
  final String? releaseName;
  final Uri? releaseUrl;
  final Uri? apkDownloadUrl;

  bool get canDownload => apkDownloadUrl != null;
}

enum AppUpdateStatus {
  updateAvailable,
  upToDate,
  latestVersionUnknown,
  noRelease,
  noAndroidApk,
}

class AppUpdateVersion implements Comparable<AppUpdateVersion> {
  const AppUpdateVersion({required this.parts, required this.buildNumber});

  final List<int> parts;
  final int buildNumber;

  static AppUpdateVersion? tryParse(String? value, {String? buildNumber}) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }

    final match = RegExp(
      r'(\d+(?:\.\d+){0,3})(?:\+(\d+))?',
    ).firstMatch(value.trim());
    if (match == null) {
      return null;
    }

    final parts = match
        .group(1)!
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
    final parsedBuildNumber =
        int.tryParse(buildNumber ?? '') ?? int.tryParse(match.group(2) ?? '');

    return AppUpdateVersion(parts: parts, buildNumber: parsedBuildNumber ?? 0);
  }

  @override
  int compareTo(AppUpdateVersion other) {
    final maxLength = parts.length > other.parts.length
        ? parts.length
        : other.parts.length;

    for (var index = 0; index < maxLength; index++) {
      final left = index < parts.length ? parts[index] : 0;
      final right = index < other.parts.length ? other.parts[index] : 0;
      if (left != right) {
        return left.compareTo(right);
      }
    }

    return buildNumber.compareTo(other.buildNumber);
  }

  @override
  String toString() {
    final versionName = parts.join('.');
    return buildNumber > 0 ? '$versionName+$buildNumber' : versionName;
  }
}
