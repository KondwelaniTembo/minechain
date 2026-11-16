import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/errors/failure_text.dart';
import 'package:minechain/core/text/app_text.dart';

ServerRefused refused(String code, {String message = 'Server says no.'}) =>
    ServerRefused(status: 400, code: code, serverMessage: message);

void main() {
  group('a code the app handles', () {
    test('uses our own sentence, not the server\'s', () {
      expect(failureText(refused(ApiCodes.invalidCredentials)),
          AppText.invalidCredentials);
    });

    // Every code handled now, with the sentence it must give.
    final handled = {
      ApiCodes.invalidCredentials: AppText.invalidCredentials,
      ApiCodes.tokenMissing: AppText.sessionNotValid,
      ApiCodes.tokenInvalid: AppText.sessionNotValid,
      ApiCodes.tokenExpired: AppText.sessionExpired,
      ApiCodes.accountPending: AppText.accountPending,
      ApiCodes.accountSuspended: AppText.accountSuspended,
      ApiCodes.accountRejected: AppText.accountRejected,
      ApiCodes.accountNotActive: AppText.accountNotActive,
      ApiCodes.forbidden: AppText.notAllowed,
      ApiCodes.tooManyRequests: AppText.tooManyTries,
      ApiCodes.validationFailed: AppText.checkTheForm,
      ApiCodes.weakPassword: AppText.weakPassword,
      ApiCodes.activationInvalid: AppText.activationInvalid,
    };
    handled.forEach((code, sentence) {
      test(code, () => expect(failureText(refused(code)), sentence));
    });
  });

  group('a code the app does not handle yet', () {
    test('falls back to the server\'s message', () {
      expect(
        failureText(refused(ApiCodes.usernameTaken,
            message: 'That username is already taken.')),
        'That username is already taken.',
      );
    });

    test('a code the app has never heard of also uses the message', () {
      expect(failureText(refused('SOME_FUTURE_CODE', message: 'New thing.')),
          'New thing.');
    });

    test('an empty server message gives a fixed sentence', () {
      expect(failureText(refused(ApiCodes.usernameTaken, message: '')),
          AppText.somethingWentWrong);
      expect(failureText(refused(ApiCodes.usernameTaken, message: '   ')),
          AppText.somethingWentWrong);
    });
  });

  group('the other failure types', () {
    test('NoConnection', () {
      expect(failureText(const NoConnection()), AppText.noConnection);
    });
    test('TimedOut', () {
      expect(failureText(const TimedOut()), AppText.timedOut);
    });
    test('InsecureConnection', () {
      expect(failureText(const InsecureConnection()),
          AppText.insecureConnection);
    });
    test('BadResponse', () {
      expect(failureText(const BadResponse(status: 502)), AppText.badResponse);
    });
  });
}
