// AppConfig.check with plain strings, so no --dart-define is needed.
// Every address here uses a reserved test name (.test, .invalid), never the
// real API's.

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/config/app_config.dart';

/// The origin the check accepted, or a test failure saying why it did not.
String acceptedOrigin(String raw) {
  final result = AppConfig.check(raw);
  return switch (result) {
    ConfigOk(:final config) => config.apiBaseUri.toString(),
    ConfigInvalid(:final problem) => fail('refused as ${problem.name}'),
  };
}

/// The reason the check refused [raw], or a test failure if it accepted it.
ConfigProblem refusal(String raw) {
  final result = AppConfig.check(raw);
  return switch (result) {
    ConfigOk() => fail('"$raw" was accepted, but should be refused'),
    ConfigInvalid(:final problem) => problem,
  };
}

void main() {
  group('accepted', () {
    test('an https origin', () {
      expect(acceptedOrigin('https://api.example.test'),
          'https://api.example.test');
    });

    test('a trailing slash is removed', () {
      expect(acceptedOrigin('https://api.example.test/'),
          'https://api.example.test');
    });

    test('a port is kept', () {
      expect(acceptedOrigin('https://api.example.test:8443'),
          'https://api.example.test:8443');
    });

    test('surrounding spaces are ignored', () {
      expect(acceptedOrigin('  https://api.example.test \n'),
          'https://api.example.test');
    });
  });

  group('refused', () {
    // Each input breaks exactly one rule, so it can only give one reason.
    final cases = <String, ConfigProblem>{
      '': ConfigProblem.missing,
      '   ': ConfigProblem.missing,
      'https://[::1': ConfigProblem.malformed,
      'http://api.example.test': ConfigProblem.notHttps,
      'api.example.test': ConfigProblem.notHttps,
      'ftp://api.example.test': ConfigProblem.notHttps,
      'https://user:secret@api.example.test': ConfigProblem.hasUserInfo,
      'https://': ConfigProblem.missingHost,
      'https://api.example.test/v1': ConfigProblem.hasPath,
      'https://api.example.test//': ConfigProblem.hasPath,
      'https://api.example.test?key=1': ConfigProblem.hasQuery,
      'https://api.example.test/?': ConfigProblem.hasQuery,
      'https://api.example.test#top': ConfigProblem.hasFragment,
    };

    cases.forEach((raw, expected) {
      test('"$raw" -> ${expected.name}', () {
        expect(refusal(raw), expected);
      });
    });
  });

  test('a refusal never repeats the value it was given', () {
    final result = AppConfig.check('https://user:secret@api.example.test');
    expect(result.toString(), isNot(contains('secret')));
    expect(result.toString(), isNot(contains('example')));
  });
}
