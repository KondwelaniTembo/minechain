// The saved session on the phone, so the user stays signed in after the app is
// closed (plan section 6.2). Exactly three keys, all in the secure store:
//
//   auth.token      the token from login
//   auth.expiresAt  when the app stops trusting it (UTC, ISO 8601)
//   auth.user       the user, as JSON
//
// The password is NEVER saved. It is used for one request and forgotten.
//
// clear() removes these three keys and nothing else: later modules keep other
// secrets in the same store (the local database key), and a logout must never
// touch them, or unsynced work would be lost (NFR-04).

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/storage/secure_store.dart';
import '../domain/user.dart';

abstract final class SessionKeys {
  static const String token = 'auth.token';
  static const String expiresAt = 'auth.expiresAt';
  static const String user = 'auth.user';

  static const List<String> all = [token, expiresAt, user];
}

/// What [SessionStore.read] found. Sealed: exactly these three.
sealed class StoredSessionRead {
  const StoredSessionRead();
}

/// Nothing usable is saved.
final class NoStoredSession extends StoredSessionRead {
  const NoStoredSession();
}

/// A user was saved whose role this app does not support. The keys have been
/// cleared.
final class UnsupportedStoredSession extends StoredSessionRead {
  const UnsupportedStoredSession();
}

/// A saved user, with the token and its expiry if they are still saved.
/// [token] and [expiresAt] are both set or both null.
final class StoredSession extends StoredSessionRead {
  const StoredSession({required this.user, this.token, this.expiresAt});

  final User user;
  final String? token;
  final DateTime? expiresAt;

  @override
  String toString() => 'StoredSession($user, hasToken: ${token != null})';
}

class SessionStore {
  SessionStore(this._store, {Clock clock = systemClock}) : _now = clock;

  final SecureStore _store;
  final Clock _now;

  /// How much earlier than the server the app treats the token as expired, so
  /// a request is not sent with a token that runs out on the way.
  static const Duration safetyMargin = Duration(seconds: 60);

  /// Saves a fresh login. Returns the expiry it saved.
  ///
  /// The token is written last: if the app is killed half-way, the worst left
  /// behind is a user with no token, which restores as "needs password"
  /// rather than as a token without its expiry.
  Future<DateTime> save({
    required User user,
    required String token,
    required int expiresIn,
  }) async {
    final expiresAt = _now()
        .toUtc()
        .add(Duration(seconds: expiresIn))
        .subtract(safetyMargin);
    await _store.write(SessionKeys.user, jsonEncode(user.toJson()));
    await _store.write(SessionKeys.expiresAt, expiresAt.toIso8601String());
    await _store.write(SessionKeys.token, token);
    return expiresAt;
  }

  /// Replaces the saved user (after GET /auth/me), keeping the token.
  Future<void> saveUser(User user) =>
      _store.write(SessionKeys.user, jsonEncode(user.toJson()));

  /// Forgets the token and its expiry, keeping the user (TOKEN_EXPIRED,
  /// decision Q2).
  Future<void> forgetToken() async {
    await _store.delete(SessionKeys.token);
    await _store.delete(SessionKeys.expiresAt);
  }

  /// Removes the three session keys, and only those.
  Future<void> clear() async {
    for (final key in SessionKeys.all) {
      await _store.delete(key);
    }
  }

  /// Reads the saved session.
  ///
  /// Anything that cannot be read or understood (the store fails, the user
  /// JSON is broken, the expiry is not a date) counts as "no session", and the
  /// three keys are cleared so the same problem does not come back at every
  /// start.
  Future<StoredSessionRead> read() async {
    final String? userJson;
    final String? token;
    final String? expiresAtText;
    try {
      userJson = await _store.read(SessionKeys.user);
      token = await _store.read(SessionKeys.token);
      expiresAtText = await _store.read(SessionKeys.expiresAt);
    } on SecureStoreException {
      await _clearQuietly();
      return const NoStoredSession();
    }

    if (userJson == null) {
      // A token without a user is useless; tidy it away.
      if (token != null || expiresAtText != null) await _clearQuietly();
      return const NoStoredSession();
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(userJson);
    } on FormatException {
      await _clearQuietly();
      return const NoStoredSession();
    }

    final User user;
    switch (User.fromJson(decoded)) {
      case UserParsed(user: final parsed):
        user = parsed;
      case UserUnsupportedRole():
        await _clearQuietly();
        return const UnsupportedStoredSession();
      case UserMalformed():
        await _clearQuietly();
        return const NoStoredSession();
    }

    // The token is only usable with its expiry. If either is missing or the
    // expiry is unreadable, forget both and keep the user.
    final expiresAt = expiresAtText == null
        ? null
        : DateTime.tryParse(expiresAtText)?.toUtc();
    if (token == null || token.isEmpty || expiresAt == null) {
      if (token != null || expiresAtText != null) {
        try {
          await forgetToken();
        } on SecureStoreException {
          // Nothing more to do: the token is not used either way.
        }
      }
      return StoredSession(user: user);
    }

    return StoredSession(user: user, token: token, expiresAt: expiresAt);
  }

  Future<void> _clearQuietly() async {
    try {
      await clear();
    } on SecureStoreException {
      // If even deleting fails there is nothing better to do; the session is
      // not used either way.
    }
  }
}

final sessionStoreProvider = Provider<SessionStore>(
  (ref) => SessionStore(
    ref.watch(secureStoreProvider),
    clock: ref.watch(clockProvider),
  ),
);
