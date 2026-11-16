// The two auth endpoints Module 3 needs, as the API documents them
// (docs/api.md):
//
//   POST /auth/login  body { "username", "password" }
//     200 { "token", "tokenType": "Bearer", "expiresIn": <seconds, at most
//           3600>, "user": { ...see User... } }
//   GET /auth/me      Authorization: Bearer <token>
//     200 { "user": { ... } }
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
