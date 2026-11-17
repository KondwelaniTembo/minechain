// The rules for signing in, staying signed in, and signing out (plan section
// 6.2, decision Q2), on top of the API (AuthApi) and the saved session
// (SessionStore).
//
// The repository decides what the server's answers mean for this phone; the
// controller (presentation/auth_controller.dart) holds the current state and
// is what screens talk to.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/network/network_providers.dart';
import '../../../core/network/pinned_http_client.dart';
import '../domain/auth_state.dart';
import '../domain/user.dart';
import 'auth_api.dart';
import 'session_store.dart';

/// The result of a login that the server accepted. (A refused one throws an
/// AppFailure.) Sealed: exactly these three.
sealed class LoginResult {
  const LoginResult();
}

final class LoggedIn extends LoginResult {
  const LoggedIn(this.session);
  final SignedIn session;
}

/// The account's role is not supported by this app. Nothing was saved.
final class LoginUnsupportedRole extends LoginResult {
  const LoginUnsupportedRole();
}

/// The password was re-entered for one account, but the server answered for
/// another. The saved session has been cleared.
final class LoginOtherAccount extends LoginResult {
  const LoginOtherAccount();
}

class AuthRepository {
  // `this._api` stores the argument in the private field; callers still
  // write `api:`.
  AuthRepository({
    required this._api,
    required this._store,
    Clock clock = systemClock,
  }) : _now = clock;

  /// Builds the AuthApi when it is first needed. It is a function, not a
  /// value, because the API client is only ready once the pinned certificates
  /// have loaded, and restoring a saved session must not wait for that.
  final Future<AuthApi> Function() _api;
  final SessionStore _store;
  final Clock _now;

  /// Logs in with [username] and [password] and saves the session.
  ///
  /// Throws an AppFailure if the server refuses (for example
  /// INVALID_CREDENTIALS) or cannot be reached. The password is only passed
  /// on; it is never kept or saved.
  Future<LoginResult> login(String username, String password) async {
    final api = await _apiOrInsecure();
    return _saveSignIn(await api.login(username, password));
  }

  /// Activates an invited account and signs in with the answer, exactly as
  /// a login does (api.md: "The answer is the same as a login's").
  ///
  /// The code and the password are only passed on; neither is kept or saved.
  Future<LoginResult> activate({
    required String username,
    required String code,
    required String password,
  }) async {
    final api = await _apiOrInsecure();
    return _saveSignIn(
      await api.activate(username: username, code: code, password: password),
    );
  }

  /// Requests a new account. Nothing is saved on the phone: the account is
  /// pending and there is no token until an administrator approves it and
  /// the person logs in.
  ///
  /// An empty or blank [licenceNumber] is sent as "no licence", because the
  /// field is optional and the server refuses an empty one.
  Future<void> register({
    required String username,
    required String fullName,
    required String password,
    required Role role,
    String? licenceNumber,
  }) async {
    final api = await _apiOrInsecure();
    final licence =
        (licenceNumber == null || licenceNumber.trim().isEmpty)
        ? null
        : licenceNumber;
    await api.register(
      username: username,
      fullName: fullName,
      password: password,
      role: role,
      licenceNumber: licence,
    );
  }

  /// Saves a login-shaped answer (login, activate) as the session.
  Future<LoginResult> _saveSignIn(LoginResponse response) async {
    final User user;
    switch (response.user) {
      case UserParsed(user: final parsed):
        user = parsed;
      case UserUnsupportedRole():
        return const LoginUnsupportedRole();
      case UserMalformed():
        throw const BadResponse(status: 200);
    }

    final expiresAt = await _store.save(
      user: user,
      token: response.token,
      expiresIn: response.expiresIn,
    );
    return LoggedIn(
      SignedIn(user: user, token: response.token, expiresAt: expiresAt),
    );
  }

  /// Logs in again as [user], who is signed in but whose token expired.
  ///
  /// The username comes from the saved user, never from the screen, so the
  /// password can only unlock the account already on this phone.
  Future<LoginResult> reauthenticate(User user, String password) async {
    final result = await login(user.username, password);
    if (result is LoggedIn && result.session.user.id != user.id) {
      await _store.clear();
      return const LoginOtherAccount();
    }
    return result;
  }

  /// The state to start in, from what is saved. Makes no request, so the app
  /// opens at once, even offline.
  Future<AuthState> restore() async {
    switch (await _store.read()) {
      case NoStoredSession():
        return const SignedOut();
      case UnsupportedStoredSession():
        return const SignedOut(reason: AuthReasons.unsupportedRole);
      case StoredSession(:final user, :final token, :final expiresAt):
        if (token != null &&
            expiresAt != null &&
            _now().toUtc().isBefore(expiresAt)) {
          return SignedIn(user: user, token: token, expiresAt: expiresAt);
        }
        // Expired by the phone's clock: keep the user and their offline
        // work, forget the token (decision Q2).
        if (token != null) await _store.forgetToken();
        return SignedInNeedsPassword(user);
    }
  }

  /// The account as the server has it now (GET /auth/me), saved over the old
  /// copy. Returns null if the server's account has a role this app does not
  /// support. Throws an AppFailure on any refusal or network failure.
  Future<User?> refreshUser(String token) async {
    final api = await _apiOrInsecure();
    switch (await api.me(token)) {
      case UserParsed(:final user):
        await _store.saveUser(user);
        return user;
      case UserUnsupportedRole():
        return null;
      case UserMalformed():
        throw const BadResponse(status: 200);
    }
  }

  /// Forgets the token, keeping the user (TOKEN_EXPIRED).
  Future<void> forgetToken() => _store.forgetToken();

  /// Signs out: removes the three session keys and nothing else.
  Future<void> logout() => _store.clear();

  /// The AuthApi, or InsecureConnection if the pinned certificates could not
  /// be loaded: nothing can connect, and that must not look like a crash.
  Future<AuthApi> _apiOrInsecure() async {
    try {
      return await _api();
    } on PinningSetupError {
      throw const InsecureConnection();
    }
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    api: () async => AuthApi(await ref.read(apiClientProvider.future)),
    store: ref.watch(sessionStoreProvider),
    clock: ref.watch(clockProvider),
  );
});
