// A pending account request, as the administrator's list shows it.
//
// It is read from the API's "admin view of a user" (docs/api.md, "Admin
// account management"), keeping only what the screen needs:
//
//   id, username, fullName, licenceNumber (or null), role, createdAt
//
// The admin view has more (statusReason, approvedBy, publicKeyFingerprint,
// ...), which this screen does not use and so does not keep.
//
// Plain Dart, no Flutter.

import '../../auth/domain/user.dart' show Role;

class AccountRequest {
  const AccountRequest({
    required this.id,
    required this.username,
    required this.fullName,
    required this.licenceNumber,
    required this.role,
    required this.requestedAt,
  });

  final String id;
  final String username;
  final String fullName;
  final String? licenceNumber;
  final Role role;

  /// When the account was requested (the API's `createdAt`), in UTC.
  final DateTime requestedAt;

  /// Reads one user from the admin view, or null if a field is missing, has
  /// the wrong type, or the role is not one this app knows.
  ///
  /// Never guesses, like User.fromJson. Extra fields are ignored, so the
  /// server may add some without breaking the list.
  static AccountRequest? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final username = json['username'];
    final fullName = json['fullName'];
    final licence = json['licenceNumber'];
    final role = json['role'];
    final createdAt = json['createdAt'];

    for (final value in [id, username, fullName, role, createdAt]) {
      if (value is! String || value.isEmpty) return null;
    }
    if (licence != null && licence is! String) return null;

    final requestedAt = DateTime.tryParse(createdAt as String);
    if (requestedAt == null) return null;

    Role? parsedRole;
    for (final r in Role.values) {
      if (r.name == role) parsedRole = r;
    }
    if (parsedRole == null) return null;

    final licenceText = licence as String?;
    return AccountRequest(
      id: id as String,
      username: username as String,
      fullName: fullName as String,
      // An empty licence is shown as "No licence number", like a missing one.
      licenceNumber: (licenceText == null || licenceText.isEmpty)
          ? null
          : licenceText,
      role: parsedRole,
      requestedAt: requestedAt.toUtc(),
    );
  }

  // Only the role: a name, username or licence number in a log or crash
  // report would be someone's personal details.
  @override
  String toString() => 'AccountRequest(role: ${role.name})';
}

/// One page of pending requests.
class AccountRequestsPage {
  const AccountRequestsPage({required this.requests, required this.total});

  final List<AccountRequest> requests;

  /// How many pending requests exist in all, not only on this page.
  final int total;

  @override
  String toString() =>
      'AccountRequestsPage(requests: ${requests.length}, total: $total)';
}
