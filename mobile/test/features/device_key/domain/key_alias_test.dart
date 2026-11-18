import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/device_key/domain/key_alias.dart';

void main() {
  const userId = '3f2b6c1e-0000-4000-8000-000000000001';

  test('the alias is the prefix followed by the user id', () {
    expect(
      deviceKeyAlias(userId),
      'minechain_signing_3f2b6c1e-0000-4000-8000-000000000001',
    );
  });

  test('two users get two different aliases', () {
    expect(
      deviceKeyAlias(userId),
      isNot(deviceKeyAlias('3f2b6c1e-0000-4000-8000-000000000002')),
    );
  });

  // Each of these would name a key the Kotlin side refuses, or a different
  // key from the one made under the server's spelling of the id.
  for (final bad in [
    '',
    '3F2B6C1E-0000-4000-8000-000000000001', // upper case: refused, not folded
    '3f2b6c1e00004000800000000000000001', // no dashes
    ' 3f2b6c1e-0000-4000-8000-000000000001', // a space
    '3f2b6c1e-0000-4000-8000-00000000000', // one digit short
    '3f2b6c1e-0000-4000-8000-000000000001\n', // a trailing line break
    'minechain_signing_3f2b6c1e-0000-4000-8000-000000000001', // already an alias
  ]) {
    test('refuses ${bad.isEmpty ? 'an empty id' : '"$bad"'}', () {
      expect(() => deviceKeyAlias(bad), throwsArgumentError);
    });
  }

  test('the error message does not repeat the id', () {
    const upper = '3F2B6C1E-0000-4000-8000-000000000001';
    expect(
      () => deviceKeyAlias(upper),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'text',
          isNot(contains(upper)),
        ),
      ),
    );
  });
}
