// toString() is what ends up in logs and crash reports, so it must carry only
// what is safe: status, code, counts. Never message or details text.

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/errors/app_failure.dart';

void main() {
  test('ServerRefused shows status and code, not message or details', () {
    const failure = ServerRefused(
      status: 400,
      code: 'WEAK_PASSWORD',
      serverMessage: 'Choose a stronger password.',
      details: [
        FieldProblem(
          field: 'password',
          code: 'PASSWORD_CONTAINS_USERNAME',
          message: 'Do not include your username in your password.',
        ),
      ],
    );

    final text = failure.toString();

    expect(text, contains('400'));
    expect(text, contains('WEAK_PASSWORD'));
    expect(text, contains('details: 1'));
    expect(text, isNot(contains('stronger')));
    expect(text, isNot(contains('PASSWORD_CONTAINS_USERNAME')));
    expect(text, isNot(contains('Do not include')));
  });

  test('BadResponse shows only its status', () {
    expect(const BadResponse(status: 502).toString(), 'BadResponse(status: 502)');
  });

  test('the other failures print only their name', () {
    expect(const NoConnection().toString(), 'NoConnection()');
    expect(const TimedOut().toString(), 'TimedOut()');
    expect(const InsecureConnection().toString(), 'InsecureConnection()');
  });
}
