// Keeps lib/core/errors/api_codes.dart and docs/api.md in step.
//
// Dart cannot list a class's constants at run time (Flutter apps have no
// reflection), so this test reads api_codes.dart as text and picks the values
// out with a pattern. It also reads docs/api.md, which is outside mobile/:
// `flutter test` runs with mobile/ as its working folder, so the path is
// ../docs/api.md. These are tests on the laptop only; nothing in the app reads
// either file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final codesFile = File('lib/core/errors/api_codes.dart');
  final apiDoc = File('../docs/api.md');

  // Every `static const String name = 'CODE';` in api_codes.dart.
  Map<String, String> constants() {
    final pattern = RegExp(r"static const String (\w+) =\s*'([A-Z0-9_]+)';");
    return {
      for (final m in pattern.allMatches(codesFile.readAsStringSync()))
        m.group(1)!: m.group(2)!,
    };
  }

  setUpAll(() {
    // A clear message if the test is run from the wrong folder, or the
    // repository layout changes, instead of a confusing file error.
    expect(apiDoc.existsSync(), isTrue,
        reason: 'docs/api.md not found at ${apiDoc.absolute.path}. '
            'Run flutter test from mobile/, inside the repository.');
    expect(codesFile.existsSync(), isTrue);
  });

  test('the pattern finds the constants (guards the test itself)', () {
    // If api_codes.dart is reformatted so the pattern no longer matches, the
    // checks below would pass with nothing checked. This stops that.
    expect(constants().length, greaterThanOrEqualTo(44));
  });

  test('every constant is a code written in docs/api.md', () {
    final doc = apiDoc.readAsStringSync();
    for (final MapEntry(key: name, value: code) in constants().entries) {
      // api.md writes codes in backticks: `CODE`, or `CODE:detail` for the
      // anchoring errors that carry a detail.
      final found = doc.contains('`$code`') || doc.contains('`$code:');
      expect(found, isTrue,
          reason: 'ApiCodes.$name is "$code", which is not in docs/api.md');
    }
  });

  test('no two constants have the same code', () {
    final values = constants().values.toList();
    expect(values.toSet().length, values.length);
  });

  test('every HTTP error code in api.md\'s tables is in ApiCodes', () {
    // Rows of api.md's error tables start "| 401 | `CODE`", sometimes with
    // several codes: "| 401 | `A`, `B`, `C` |".
    final row = RegExp(r'^\| \d{3} \| (`[A-Z0-9_]+`(?:, `[A-Z0-9_]+`)*)',
        multiLine: true);
    final code = RegExp(r'`([A-Z0-9_]+)`');
    final documented = <String>{
      for (final r in row.allMatches(apiDoc.readAsStringSync()))
        for (final c in code.allMatches(r.group(1)!)) c.group(1)!,
    };

    expect(documented, isNotEmpty);
    final missing = documented.difference(constants().values.toSet());
    expect(missing, isEmpty,
        reason: 'api.md has error codes that ApiCodes does not: $missing');
  });
}
