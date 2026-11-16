// Where the app is with signing in (plan section 6.1, decision Q2).
//
// A sealed class is a "state machine" made of types: the app is in exactly one
// of these four at any moment, and a `switch` over them must handle all four.
// The router (F7) will decide which screen to show from this alone.
//
//   AuthUnknown ──restore()──► SignedOut / SignedIn / SignedInNeedsPassword
//   SignedOut ──logIn()──► SignedIn
//   SignedIn ──TOKEN_EXPIRED──► SignedInNeedsPassword ──reauthenticate()──► SignedIn
//   SignedIn / SignedInNeedsPassword ──logOut(), or another refusal──► SignedOut

import 'user.dart';

sealed class AuthState {
  const AuthState();
}

/// Start-up: the saved session has not been read yet.
final class AuthUnknown extends AuthState {
  const AuthUnknown();
}

/// Nobody is signed in on this phone.
final class SignedOut extends AuthState {
  const SignedOut({this.reason});

  /// Why the user was signed out, if it was not their own choice: an API code
  /// such as `ACCOUNT_SUSPENDED` or `TOKEN_INVALID`, or one of [AuthReasons].
  /// The login screen (F7) turns it into a sentence. Null after a normal
  /// logout or when nobody had signed in.
  final String? reason;

  @override
  String toString() => 'SignedOut(reason: $reason)';
}

/// Signed in, with a token the app believes is still valid.
final class SignedIn extends AuthState {
  const SignedIn({
    required this.user,
    required this.token,
    required this.expiresAt,
  });

  final User user;
  final String token;

  /// When the app stops trusting the token (UTC), a minute before the server
  /// would. The server's answer always wins over this.
  final DateTime expiresAt;

  // Never the token.
  @override
  String toString() => 'SignedIn($user)';
}

/// The user is known, but the token has expired (decision Q2). Their home and
/// offline work stay open; the password is asked for again before the next
/// server action.
final class SignedInNeedsPassword extends AuthState {
  const SignedInNeedsPassword(this.user);

  final User user;

  @override
  String toString() => 'SignedInNeedsPassword($user)';
}

/// Sign-out reasons that come from the app itself, not from an API code.
abstract final class AuthReasons {
  /// The account's role is not one this version of the app supports
  /// (plan section 4.1): "Please update the app."
  static const String unsupportedRole = 'APP_UNSUPPORTED_ROLE';

  /// The password was entered again, but the server answered for a different
  /// account than the one signed in on this phone.
  static const String accountChanged = 'APP_ACCOUNT_CHANGED';
}
