import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/app_update/domain/entities/app_update_check.dart';

void main() {
  group('AppUpdateVersion', () {
    test('parses pubspec style versions', () {
      final version = AppUpdateVersion.tryParse('v0.2.1+7');

      expect(version.toString(), '0.2.1+7');
    });

    test('compares version names before build numbers', () {
      final current = AppUpdateVersion.tryParse('0.1.9+99')!;
      final latest = AppUpdateVersion.tryParse('0.2.0+1')!;

      expect(latest.compareTo(current), greaterThan(0));
    });

    test('uses package build number when version has no build suffix', () {
      final current = AppUpdateVersion.tryParse('0.1.0', buildNumber: '1')!;
      final latest = AppUpdateVersion.tryParse('0.1.0+2')!;

      expect(latest.compareTo(current), greaterThan(0));
    });
  });
}
