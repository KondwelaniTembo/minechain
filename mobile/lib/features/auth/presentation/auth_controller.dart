// The app's sign-in state, and the only way to change it (plan sections 4.3,
// 6.1-6.3; decision Q2).
//
// Screens (from F7) watch `authControllerProvider` to know who is signed in,
// and call logIn / reauthenticate / logOut, and (F9) register / activate.
// They never touch the token, the
// saved session or the API.
//
// Dependency direction: auth uses the network layer (ApiClient, SessionEvents),
// never the reverse. The network layer only announces "the server refused this
// session"; this controller decides what that means.
//
// Nothing here is logged: no token, password, username or user JSON.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/network/network_providers.dart';
import '../../../core/storage/secure_store.dart';
import '../data/auth_repository.dart';
import '../domain/auth_state.dart';
import '../domain/user.dart';

/// What a logIn or reauthenticate call came to, for the form that called it.
/// Sealed: exactly these four.
sealed class LoginOutcome {
  const LoginOutcome();
}

/// Signed in; the state is now SignedIn.
final class LoginSucceeded extends LoginOutcome {
  const LoginSucceeded();
}

/// Refused or failed; show `failureText(failure)` on the form.
final class LoginFailed extends LoginOutcome {
  const LoginFailed(this.failure);
  final AppFailure failure;
}

/// The server accepted the password, but the account cannot be used with this
/// app (an unknown role, or a different account than the one on this phone).
/// The state is SignedOut with the reason.
final class LoginNotPossible extends LoginOutcome {
  const LoginNotPossible(this.reason);

  /// One of [AuthReasons].
  final String reason;
}

/// This call did nothing: another sign-in or sign-out was already running, or
/// there was nothing to do (a password re-entered while not asked for).
final class LoginIgnored extends LoginOutcome {
  const LoginIgnored();
}

/// What an account request came to, for the register form. Sealed: exactly
/// these three. A request never signs anyone in (the account is pending).
sealed class RegisterOutcome {
  const RegisterOutcome();
}

/// The server accepted the request. Show the confirmation.
final class RegisterSent extends RegisterOutcome {
  const RegisterSent();
}

/// Refused or failed; the form shows the failure (and any details under
/// their fields).
final class RegisterFailed extends RegisterOutcome {
  const RegisterFailed(this.failure);
  final AppFailure failure;
}

/// Another sign-in, sign-out or request was already running; nothing sent.
final class RegisterIgnored extends RegisterOutcome {
  const RegisterIgnored();
}

/// Announces each fresh sign-in (a login, a re-entered password, or a saved
/// session restored at start-up), for steps that must run after one, such as
/// registering the device key (plan section 6.3, a later module).
class SignedInEvents {
  final StreamController<User> _controller = StreamController<User>.broadcast();

  Stream<User> get users => _controller.stream;

  void report(User user) {
    if (!_controller.isClosed) _controller.add(user);
  }

  void dispose() => _controller.close();
}

final signedInEventsProvider = Provider<SignedInEvents>((ref) {
  final events = SignedInEvents();
  ref.onDispose(events.dispose);
  return events;
});

class AuthController extends Notifier<AuthState> {
  /// True while a logIn, reauthenticate or logOut is running.
  bool _busy = false;

  /// The refusal codes (401 token, 403 account) that end the session for good.
  /// TOKEN_EXPIRED is not here: it only asks for the password again.
  static const Set<String> _fullLogout = {
    ApiCodes.tokenInvalid,
    ApiCodes.tokenMissing,
    ApiCodes.accountPending,
    ApiCodes.accountSuspended,
    ApiCodes.accountRejected,
    ApiCodes.accountNotActive,
  };

  AuthRepository get _repository => ref.read(authRepositoryProvider);

  @override
  AuthState build() {
    // Listen to the network layer's announcements for as long as this
    // controller exists, and stop when it is thrown away.
    final subscription = ref
        .read(sessionEventsProvider)
        .refusals
        .listen(_onSessionRefused);
    ref.onDispose(subscription.cancel);
    return const AuthUnknown();
  }

  /// Reads the saved session. Called once at start-up (main.dart). Makes no
  /// request first, so the app opens at once, even offline; the user's
  /// details are then refreshed from the server in the background.
  Future<void> restore() async {
    if (state is! AuthUnknown) return;

    AuthState restored;
    try {
      restored = await _repository.restore();
    } on SecureStoreException {
      // The saved session could not be used; start signed out.
      restored = const SignedOut();
    }
    if (!ref.mounted || state is! AuthUnknown) return;
    state = restored;

    if (restored is SignedIn) {
      // The repository has just compared the saved expiry with the clock;
      // asking checkExpiry() once more keeps "has the token run out?" decided
      // by one rule everywhere (here, and on resume). It costs nothing.
      await checkExpiry();
      if (!ref.mounted || state is! SignedIn) return;

      _announceSignedIn(restored.user);
      // Deliberately not awaited: start-up must not wait for the server,
      // which may take a minute to wake.
      unawaited(_refreshUser(restored));
    }
  }

  /// Logs in. The outcome is for the form: the failure to show, if any.
  Future<LoginOutcome> logIn(String username, String password) {
    return _exclusively(() async {
      final LoginResult result;
      try {
        result = await _repository.login(username, password);
      } on AppFailure catch (failure) {
        // Wrong password, no network, ...: nothing was saved and the state
        // stays as it was. The form shows the failure.
        return LoginFailed(failure);
      }
      return _apply(result);
    }, ignored: const LoginIgnored());
  }

  /// Activates an officer or administrator account with the code from an
  /// administrator, and signs in exactly like a login: the session is saved,
  /// SignedInEvents hears of it, and the router moves to the role's home.
  Future<LoginOutcome> activate({
    required String username,
    required String code,
    required String password,
  }) {
    return _exclusively(() async {
      final LoginResult result;
      try {
        result = await _repository.activate(
          username: username,
          code: code,
          password: password,
        );
      } on AppFailure catch (failure) {
        // ACTIVATION_INVALID, WEAK_PASSWORD, no network, ...: nothing was
        // saved, still signed out.
        return LoginFailed(failure);
      }
      return _apply(result);
    }, ignored: const LoginIgnored());
  }

  /// Requests a new account. Never changes the sign-in state: the account is
  /// pending until an administrator approves it, and only then can its owner
  /// log in.
  Future<RegisterOutcome> register({
    required String username,
    required String fullName,
    required String password,
    required Role role,
    String? licenceNumber,
  }) {
    return _exclusively(() async {
      try {
        await _repository.register(
          username: username,
          fullName: fullName,
          password: password,
          role: role,
          licenceNumber: licenceNumber,
        );
      } on AppFailure catch (failure) {
        return RegisterFailed(failure);
      }
      return const RegisterSent();
    }, ignored: const RegisterIgnored());
  }

  /// Enters the password again after the token expired (decision Q2), for
  /// the user already signed in on this phone.
  Future<LoginOutcome> reauthenticate(String password) {
    return _exclusively(() async {
      final current = state;
      if (current is! SignedInNeedsPassword) {
        // Nothing to re-enter the password for.
        return const LoginIgnored();
      }

      final LoginResult result;
      try {
        result = await _repository.reauthenticate(current.user, password);
      } on AppFailure catch (failure) {
        // A suspended or otherwise blocked account (403 at login) is a full
        // logout, as for the same answer to any other request (plan 4.3).
        if (failure is ServerRefused &&
            failure.status == 403 &&
            _fullLogout.contains(failure.code)) {
          await _signOut(failure.code);
        }
        return LoginFailed(failure);
      }
      return _apply(result);
    }, ignored: const LoginIgnored());
  }

  /// Has the token run out by the phone's clock? If so, forget it and ask for
  /// the password again (decision Q2), exactly as if the server had answered
  /// TOKEN_EXPIRED, but without sending anything.
  ///
  /// Called when the app comes back to the screen (SessionExpiryWatcher) and
  /// once after restore(). A phone in a pocket for two hours wakes up already
  /// knowing it must ask for the password, instead of finding out from a
  /// refused request, which needs a network the miner may not have.
  ///
  /// "At or after" expiresAt counts as expired. expiresAt is already a minute
  /// before the server's own limit (plan 6.2), so the app stops one minute
  /// early rather than one second late.
  Future<void> checkExpiry() async {
    // A login or logout is running and will set the state itself.
    if (_busy) return;
    final current = state;
    // Only a SignedIn session has a token that can run out.
    if (current is! SignedIn) return;

    final now = ref.read(clockProvider)();
    if (now.isBefore(current.expiresAt)) return;
    await _expireToken(current);
  }

  /// Signs out by the user's choice.
  ///
  /// Local only: the API has no logout endpoint, because its tokens are
  /// stateless (api.md, "Authentication"). Forgetting the token on this phone
  /// is the whole logout.
  Future<void> logOut() async {
    await _exclusively(() async {
      await _signOut(null);
      return const LoginSucceeded();
    }, ignored: const LoginIgnored());
  }

  /// Takes a fresher copy of the signed-in user from the server, for example
  /// the answer to PUT /auth/me/public-key with the new fingerprint (M2).
  /// The caller has already saved it. Only for the same account: an answer
  /// for anyone else is ignored. It changes no token and announces no
  /// sign-in.
  void userUpdated(User user) {
    final current = state;
    switch (current) {
      case SignedIn() when current.user.id == user.id:
        state = SignedIn(
          user: user,
          token: current.token,
          expiresAt: current.expiresAt,
        );
      case SignedInNeedsPassword() when current.user.id == user.id:
        state = SignedInNeedsPassword(user);
      case _:
        break;
    }
  }

  // ---- inside ----

  /// Runs [action] unless another sign-in, sign-out or account request is
  /// already running; then it answers [ignored] at once and sends nothing.
  ///
  /// `<T>` makes it generic: the same guard works for actions that answer a
  /// LoginOutcome and for ones that answer a RegisterOutcome.
  Future<T> _exclusively<T>(
    Future<T> Function() action, {
    required T ignored,
  }) async {
    if (_busy) return ignored;
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }

  Future<LoginOutcome> _apply(LoginResult result) async {
    switch (result) {
      case LoggedIn(:final session):
        if (ref.mounted) state = session;
        _announceSignedIn(session.user);
        return const LoginSucceeded();
      case LoginUnsupportedRole():
        await _signOut(AuthReasons.unsupportedRole);
        return const LoginNotPossible(AuthReasons.unsupportedRole);
      case LoginOtherAccount():
        await _signOut(AuthReasons.accountChanged);
        return const LoginNotPossible(AuthReasons.accountChanged);
    }
  }

  /// Gets the server's current copy of the user, without blocking anything.
  /// A refusal (401, 403) is handled by the SessionEvents listener; any
  /// other failure (no network, server asleep) just keeps the saved copy.
  Future<void> _refreshUser(SignedIn session) async {
    final User? fresh;
    try {
      fresh = await _repository.refreshUser(session.token);
    } on AppFailure {
      return;
    } on SecureStoreException {
      return;
    }
    if (!ref.mounted) return;
    final current = state;
    // Only if nothing changed meanwhile (same session still signed in).
    if (current is! SignedIn || current.token != session.token) return;
    if (fresh == null) {
      await _signOut(AuthReasons.unsupportedRole);
      return;
    }
    state = SignedIn(
      user: fresh,
      token: current.token,
      expiresAt: current.expiresAt,
    );
  }

  /// The network layer saw the server refuse a request that carried a token.
  ///
  /// A known limit: the event names only the code, not which token was used,
  /// so a slow request with an old token could arrive after a fresh login.
  /// That is rare and the effect is only an extra password prompt or logout.
  Future<void> _onSessionRefused(String code) async {
    final current = state;
    // Signed out already (or not started): nothing to end.
    if (current is SignedOut || current is AuthUnknown) return;

    if (code == ApiCodes.tokenExpired) {
      // Keep the user and their offline work; ask for the password before
      // the next server action (decision Q2).
      if (current is SignedIn) await _expireToken(current);
      return;
    }

    if (_fullLogout.contains(code)) {
      await _signOut(code);
    }
    // Any other code (for example FORBIDDEN) changes nothing here.
  }

  /// Forgets [session]'s token but keeps the user: SignedIn becomes
  /// SignedInNeedsPassword. Shared by TOKEN_EXPIRED and checkExpiry().
  Future<void> _expireToken(SignedIn session) async {
    try {
      await _repository.forgetToken();
    } on SecureStoreException {
      // The token is no longer used either way.
    }
    if (!ref.mounted) return;
    final current = state;
    // Only if that same session is still signed in: a logout that finished
    // meanwhile must not be turned back into "signed in".
    if (current is SignedIn && current.token == session.token) {
      // current.user, not session.user: it may have been refreshed since.
      state = SignedInNeedsPassword(current.user);
    }
  }

  /// Removes the saved session and shows the user as signed out.
  Future<void> _signOut(String? reason) async {
    try {
      await _repository.logout();
    } on SecureStoreException {
      // Signed out in memory anyway; the next start tries to read the keys,
      // and clears them if they are unusable.
    }
    if (ref.mounted) state = SignedOut(reason: reason);
  }

  void _announceSignedIn(User user) =>
      ref.read(signedInEventsProvider).report(user);
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
