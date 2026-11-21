// TEST ONLY: stand-ins for the auth and server-status controllers, so screen
// and router tests need no network, no secure storage and no timers.

// Riverpod 3 keeps less-used types such as Override in misc.dart.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:minechain/core/network/server_status.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/auth_controller.dart';

import 'auth_fixtures.dart';

/// Holds a fixed state; logIn records its arguments and answers with
/// [answer] (success by default). reauthenticate records the password and
/// answers with [reauthAnswer]; by default it succeeds and becomes SignedIn,
/// as the real controller would. logOut and checkExpiry only count (logOut
/// also becomes SignedOut, so the router moves).
///
/// register records what the form sent and answers with [registerAnswer]
/// (RegisterSent by default), never changing the state. activate records
/// its arguments and answers with [activateAnswer]; by default it signs in
/// as an officer, as the real controller would after a good code.
class FakeAuthController extends AuthController {
  FakeAuthController(
    this.initial, {
    this.answer,
    this.reauthAnswer,
    this.registerAnswer,
    this.activateAnswer,
  });

  final AuthState initial;
  Future<LoginOutcome> Function(String username, String password)? answer;
  Future<LoginOutcome> Function(String password)? reauthAnswer;
  Future<RegisterOutcome> Function()? registerAnswer;
  Future<LoginOutcome> Function()? activateAnswer;

  /// Every register call's fields, in order (test-only, password included).
  final List<Map<String, Object?>> registerCalls = [];

  /// Every activate call's fields, in order (test-only).
  final List<Map<String, String>> activateCalls = [];

  /// Every logIn call, in order. (Test-only: the real controller keeps no
  /// password anywhere.)
  final List<(String, String)> logInCalls = [];

  /// Every password given to reauthenticate, in order. (Test-only too.)
  final List<String> reauthenticateCalls = [];

  int logOutCalls = 0;
  int expiryChecks = 0;

  @override
  AuthState build() => initial;

  @override
  Future<void> restore() async {}

  @override
  Future<LoginOutcome> logIn(String username, String password) {
    logInCalls.add((username, password));
    return answer?.call(username, password) ??
        Future.value(const LoginSucceeded());
  }

  @override
  Future<LoginOutcome> reauthenticate(String password) async {
    reauthenticateCalls.add(password);
    final custom = reauthAnswer;
    if (custom != null) return custom(password);
    final current = state;
    if (current is! SignedInNeedsPassword) return const LoginIgnored();
    state = SignedIn(
      user: current.user,
      token: fakeToken,
      expiresAt: DateTime.utc(2026, 11, 16, 10),
    );
    return const LoginSucceeded();
  }

  @override
  Future<RegisterOutcome> register({
    required String username,
    required String fullName,
    required String password,
    required Role role,
    String? licenceNumber,
  }) async {
    registerCalls.add({
      'username': username,
      'fullName': fullName,
      'password': password,
      'role': role,
      'licenceNumber': licenceNumber,
    });
    return registerAnswer?.call() ?? const RegisterSent();
  }

  @override
  Future<LoginOutcome> activate({
    required String username,
    required String code,
    required String password,
  }) async {
    activateCalls.add({
      'username': username,
      'code': code,
      'password': password,
    });
    final custom = activateAnswer;
    if (custom != null) return custom();
    state = signedInAs(Role.officer);
    return const LoginSucceeded();
  }

  @override
  Future<void> logOut() async {
    logOutCalls++;
    state = const SignedOut();
  }

  @override
  Future<void> checkExpiry() async => expiryChecks++;

  /// How many times refreshAccount ran ("My account", admin accounts T6b).
  int accountRefreshes = 0;

  /// What refreshAccount turns the user into, as GET /auth/me would; null
  /// keeps the user as it is.
  User? refreshedUser;

  @override
  Future<void> refreshAccount() async {
    accountRefreshes++;
    final fresh = refreshedUser;
    final current = state;
    if (fresh != null && current is SignedIn) {
      state = SignedIn(
        user: fresh,
        token: current.token,
        expiresAt: current.expiresAt,
      );
    }
  }

  /// Lets a test move the state, as the real controller would.
  void setState(AuthState next) => state = next;
}

/// Holds a fixed state; check() only counts.
class FakeServerStatus extends ServerStatusController {
  FakeServerStatus([this.initial = const ServerUnknown()]);
  final ServerStatus initial;
  int checks = 0;

  @override
  ServerStatus build() => initial;

  @override
  Future<void> check() async => checks++;
}

/// A signed-in state for [role].
SignedIn signedInAs(Role role) => SignedIn(
  user: userOf(role),
  token: fakeToken,
  expiresAt: DateTime.utc(2026, 11, 16, 10),
);

User userOf(Role role) =>
    (User.fromJson(userJson(role: role.name)) as UserParsed).user;

/// Overrides that put [auth] (and an idle server status) in place.
List<Override> fakeOverrides(
  FakeAuthController auth, {
  FakeServerStatus? server,
}) => [
  authControllerProvider.overrideWith(() => auth),
  serverStatusControllerProvider.overrideWith(
    () => server ?? FakeServerStatus(),
  ),
];
