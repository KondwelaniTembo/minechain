// The auth endpoints Module 3 needs, as the API documents them
// (docs/api.md):
//
//   POST /auth/login     body { "username", "password" }
//     200 { "token", "tokenType": "Bearer", "expiresIn": <seconds, at most
//           3600>, "user": { ...see User... } }
//   GET /auth/me         Authorization: Bearer <token>
//     200 { "user": { ... } }
//   POST /auth/register  body { "username", "fullName", "password", "role",
//                               "licenceNumber"? }   (F9)
//     201 { "user": { ...status "pending"... }, "message" }   no token
//   POST /auth/activate  body { "username", "code", "password" }   (F9)
//     200 exactly the shape of a login: the app is signed in at once
//
// The server refuses any field it does not know (VALIDATION_FAILED), so each
// body has exactly the documented fields and nothing else.
//
// This file only turns those answers into Dart values. Deciding what they mean
// for the session is the repository's job.

import '../../../core/errors/app_failure.dart';
import '../../../core/network/api_client.dart';
import '../domain/user.dart';

/// A successful login's answer.
class LoginResponse {
  const LoginResponse({
    required this.token,
    required this.expiresIn,
    required this.user,
  });

  final String token;

  /// How long the token lasts, in seconds.
  final int expiresIn;

  /// The account, which may have a role this app does not support.
  final UserParseResult user;

  @override
  String toString() => 'LoginResponse(expiresIn: $expiresIn)';
}

class AuthApi {
  AuthApi(this._api);

  final ApiClient _api;

  /// The longest token the API issues (api.md: "never more than 3600"). A
  /// larger value is treated as this, so the app never trusts a token for
  /// longer than NFR-01's 60 minutes.
  static const int maxExpiresIn = 3600;

  /// POST /auth/login. Throws an AppFailure if refused (for example 401
  /// INVALID_CREDENTIALS) or if the answer is not the documented shape.
  Future<LoginResponse> login(String username, String password) async {
    final json = await _api.post(
      const ['auth', 'login'],
      body: {'username': username, 'password': password},
    );
    return _signInAnswer(json);
  }

  /// POST /auth/activate: an invited officer or administrator account,
  /// activated with the code an administrator gave its owner, and a password
  /// the owner chooses. The answer is a login's, so it is read the same way.
  ///
  /// [code] is sent exactly as typed: the server accepts any letter case,
  /// spaces and dashes (api.md "The activation code"), and says "not
  /// trimmed".
  Future<LoginResponse> activate({
    required String username,
    required String code,
    required String password,
  }) async {
    final json = await _api.post(
      const ['auth', 'activate'],
      body: {'username': username, 'code': code, 'password': password},
    );
    return _signInAnswer(json);
  }

  /// POST /auth/register: asks for a new miner, transporter or buyer
  /// account. It starts as pending, and the answer has no token, so nothing
  /// is signed in. Throws an AppFailure if refused (for example
  /// USERNAME_TAKEN or WEAK_PASSWORD).
  ///
  /// [licenceNumber] is left out of the body when null: the field is
  /// optional, and an empty string would break its 1–50 character rule.
  ///
  /// The answer's body is not checked any further. A 201 means the account
  /// now exists; calling that a failure because of an odd echo of the user
  /// would make the person try again and get USERNAME_TAKEN.
  Future<void> register({
    required String username,
    required String fullName,
    required String password,
    required Role role,
    String? licenceNumber,
  }) async {
    if (!registrableRoles.contains(role)) {
      // A programming mistake, not a user error: the screen only offers the
      // three roles. ArgumentError is an Error, so it fails loudly in tests.
      throw ArgumentError.value(role.name, 'role', 'cannot be requested');
    }
    await _api.post(
      const ['auth', 'register'],
      body: {
        'username': username,
        'fullName': fullName,
        'password': password,
        'role': role.name,
        // A "null-aware entry" (the ? before the value): the key is only put
        // in the map when the value is not null, so a missing licence leaves
        // the field out altogether instead of sending "licenceNumber": null.
        'licenceNumber': ?licenceNumber,
      },
    );
  }

  /// Reads a login-shaped answer (login and activate).
  static LoginResponse _signInAnswer(Object? json) {
    if (json is! Map) throw const BadResponse(status: 200);
    final token = json['token'];
    final tokenType = json['tokenType'];
    final expiresIn = json['expiresIn'];
    if (token is! String ||
        token.isEmpty ||
        tokenType != 'Bearer' ||
        expiresIn is! int ||
        expiresIn <= 0) {
      throw const BadResponse(status: 200);
    }

    return LoginResponse(
      token: token,
      expiresIn: expiresIn > maxExpiresIn ? maxExpiresIn : expiresIn,
      user: User.fromJson(json['user']),
    );
  }

  /// GET /auth/me: the account as the server has it now.
  Future<UserParseResult> me(String token) async {
    final json = await _api.get(const ['auth', 'me'], token: token);
    if (json is! Map) throw const BadResponse(status: 200);
    return User.fromJson(json['user']);
  }
}
