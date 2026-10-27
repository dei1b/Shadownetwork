import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/validation/domain/services/validation_run_identity.dart';

void main() {
  test('normalizes shared codes without accepting invalid characters', () {
    expect(
      ValidationRunIdentity.normalizeCode(' panabo-2026-001 '),
      'PANABO-2026-001',
    );
    expect(ValidationRunIdentity.normalizeCode('a_1'), 'A_1');
    expect(ValidationRunIdentity.normalizeCode('a' * 48), 'A' * 48);
    for (final code in [
      '',
      'aa',
      'a' * 49,
      'ABC DEF',
      'ABC!',
      '-ABC',
      'ABC-',
      '_ABC',
      'ABC_',
      'ABß',
      'ＡBC',
    ]) {
      expect(
        () => ValidationRunIdentity.normalizeCode(code),
        throwsFormatException,
        reason: code,
      );
    }
  });

  test('generates independently reusable 128-bit random run codes', () {
    final codes = List.generate(
      50,
      (_) => ValidationRunIdentity.generateCode(now: DateTime(2026, 10, 26)),
    );
    expect(codes.toSet(), hasLength(50));
    for (final code in codes) {
      expect(code, matches(RegExp(r'^SN-20261026-[A-F0-9]{32}$')));
      expect(ValidationRunIdentity.normalizeCode(code), code);
    }
  });

  test(
    'QR encodes only grouping identity and accepts supported extra metadata',
    () {
      final encoded = ValidationRunIdentity.encodeQr(' panabo-2026-001 ');
      expect(jsonDecode(encoded), {
        'schema_version': 1,
        'bundle_type': 'shadow_network_validation_run',
        'test_run_id': 'PANABO-2026-001',
      });
      expect(ValidationRunIdentity.decodeQr(encoded), 'PANABO-2026-001');
      expect(
        ValidationRunIdentity.decodeQr(
          jsonEncode({
            'schema_version': 1,
            'bundle_type': 'shadow_network_validation_run',
            'test_run_id': 'panabo-2026-001',
            'description': 'Trial',
          }),
        ),
        'PANABO-2026-001',
      );
    },
  );

  test(
    'QR rejects unrelated, malformed, future, oversized and invalid identity inputs',
    () {
      final valid = {
        'schema_version': 1,
        'bundle_type': 'shadow_network_validation_run',
        'test_run_id': 'ABC-123',
      };
      final inputs = [
        '',
        'ABC-123',
        '[]',
        'null',
        'https://example.com',
        jsonEncode({...valid, 'bundle_type': 'shadow_network_trust_bundle'}),
        jsonEncode({...valid, 'schema_version': 2}),
        jsonEncode({...valid, 'schema_version': '1'}),
        jsonEncode({...valid, 'test_run_id': null}),
        jsonEncode({...valid, 'test_run_id': 123}),
        jsonEncode({...valid, 'test_run_id': 'bad code'}),
        jsonEncode({...valid, 'extra': 'x' * 1024}),
        jsonEncode({...valid, 'extra': 'é' * 500}),
      ];
      for (final input in inputs) {
        expect(
          () => ValidationRunIdentity.decodeQr(input),
          throwsFormatException,
          reason: input.substring(0, input.length.clamp(0, 80)),
        );
      }
    },
  );
}
