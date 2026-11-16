// A MineChain account, as the API describes it (docs/api.md, the `user` object
// in POST /auth/login and GET /auth/me):
//
//   id, username, fullName, licenceNumber (or null), role, status,
//   createdAt, publicKeyFingerprint (or null)
//
// Plain Dart, no Flutter: this is the app's own idea of a user, not tied to
// any screen.

/// The five roles (FR-06). The names are exactly the API's.
enum Role { miner, transporter, buyer, officer, admin }

/// The six account statuses (api.md "Account statuses").
enum AccountStatus { pending, active, suspended, rejected, invited, deleted }

class User {
  const User({
    required this.id,
    required this.username,
    required this.fullName,
    required this.licenceNumber,
    required this.role,
    required this.status,
    required this.createdAt,
    required this.publicKeyFingerprint,
  });

  final String id;
  final String username;
  final String fullName;
  final String? licenceNumber;
  final Role role;
  final AccountStatus status;
  final DateTime createdAt;

  /// The SHA-256 of this account's registered device key, or null if none is
  /// registered yet. Compared with this phone's key in a later module (plan
  /// section 6.3).
  final String? publicKeyFingerprint;

  /// Reads a user from JSON (from the API, or as saved on the phone).
  ///
  /// Never guesses: a missing or wrongly typed field gives [UserMalformed], and
  /// a role this app does not know gives [UserUnsupportedRole]. Extra fields
  /// are ignored, so the server may add some without breaking the app.
  static UserParseResult fromJson(Object? json) {
    if (json is! Map) return const UserMalformed();

    final id = json['id'];
    final username = json['username'];
    final fullName = json['fullName'];
    final licenceNumber = json['licenceNumber'];
    final role = json['role'];
    final status = json['status'];
    final createdAt = json['createdAt'];
    final fingerprint = json['publicKeyFingerprint'];

    // Required text fields must be present, text, and not empty.
    for (final value in [id, username, fullName, role, status, createdAt]) {
      if (value is! String || value.isEmpty) return const UserMalformed();
    }
    // The two optional fields are always sent by the API, as text or as null.
    // A missing key is refused like any other missing field.
    if (!json.containsKey('licenceNumber') ||
        !json.containsKey('publicKeyFingerprint')) {
      return const UserMalformed();
    }
    if (licenceNumber != null && licenceNumber is! String) {
      return const UserMalformed();
    }
    if (fingerprint != null && fingerprint is! String) {
      return const UserMalformed();
    }

    final parsedCreatedAt = DateTime.tryParse(createdAt as String);
    if (parsedCreatedAt == null) return const UserMalformed();

    final parsedStatus = _byName(AccountStatus.values, status as String);
    if (parsedStatus == null) return const UserMalformed();

    // An unknown role is not a broken answer: it may be a role added on the
    // server after this app was built. It gets its own result so the app can
    // say "update the app" instead of guessing what the user may do.
    final parsedRole = _byName(Role.values, role as String);
    if (parsedRole == null) return const UserUnsupportedRole();

    return UserParsed(
      User(
        id: id as String,
        username: username as String,
        fullName: fullName as String,
        licenceNumber: licenceNumber as String?,
        role: parsedRole,
        status: parsedStatus,
        createdAt: parsedCreatedAt.toUtc(),
        publicKeyFingerprint: fingerprint as String?,
      ),
    );
  }

  /// The same fields as the API sends, so [fromJson] reads it back.
  Map<String, Object?> toJson() => {
    'id': id,
    'username': username,
    'fullName': fullName,
    'licenceNumber': licenceNumber,
    'role': role.name,
    'status': status.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'publicKeyFingerprint': publicKeyFingerprint,
  };

  // Only the role: a name, username or licence number in a log or crash
  // report would be someone's personal details.
  @override
  String toString() => 'User(role: ${role.name})';

  @override
  bool operator ==(Object other) =>
      other is User &&
      other.id == id &&
      other.username == username &&
      other.fullName == fullName &&
      other.licenceNumber == licenceNumber &&
      other.role == role &&
      other.status == status &&
      other.createdAt == createdAt &&
      other.publicKeyFingerprint == publicKeyFingerprint;

  @override
  int get hashCode => Object.hash(
    id,
    username,
    fullName,
    licenceNumber,
    role,
    status,
    createdAt,
    publicKeyFingerprint,
  );
}

/// The enum value named [name] exactly, or null.
T? _byName<T extends Enum>(List<T> values, String name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

/// What [User.fromJson] found. Sealed: exactly these three.
sealed class UserParseResult {
  const UserParseResult();
}

final class UserParsed extends UserParseResult {
  const UserParsed(this.user);
  final User user;
}

/// The role is not one of the five this app knows.
final class UserUnsupportedRole extends UserParseResult {
  const UserUnsupportedRole();
}

/// A field is missing or has the wrong type.
final class UserMalformed extends UserParseResult {
  const UserMalformed();
}
