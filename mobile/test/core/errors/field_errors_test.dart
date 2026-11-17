import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/errors/field_errors.dart';

void main() {
  test('no details -> no field errors', () {
    expect(fieldErrorsFrom(const []), isEmpty);
  });

  test('each field gets its own message', () {
    expect(
      fieldErrorsFrom(const [
        FieldProblem(field: 'username', message: 'is too short'),
        FieldProblem(field: 'fullName', message: 'is required'),
      ]),
      {'username': 'is too short', 'fullName': 'is required'},
    );
  });

  test('several problems for one field are joined, in order, once each', () {
    expect(
      fieldErrorsFrom(const [
        FieldProblem(field: 'password', message: 'Too short.', code: 'A'),
        FieldProblem(field: 'password', message: 'Too common.', code: 'B'),
        FieldProblem(field: 'password', message: 'Too short.', code: 'A'),
      ]),
      {'password': 'Too short.\nToo common.'},
    );
  });
}
