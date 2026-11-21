// One account as the administrator's "Accounts" screens show it (admin
// accounts plan, T1), read from the API's "admin view of a user" (docs/api.md,
// "Admin account management"):
//
//   id, username, fullName, licenceNumber, role, status, statusReason,
//   approvedBy, approvedAt, createdAt, updatedAt, publicKeyFingerprint,
//   activationExpiresAt
//
// `approvedBy` (an administrator's id) and `updatedAt` are not shown, so they
// are not kept. Unlike AccountRequest, which keeps only what a pending card
// needs, this keeps everything the account page shows for any status.
//
// Plain Dart, no Flutter.

import '../../auth/domain/user.dart' show AccountStatus, Role;

/// The roles whose accounts hold a device key (they sign custody steps).
const Set<Role> keyHoldingRoles = {Role.miner, Role.transporter, Role.buyer};

class AdminAccount {
  const AdminAccount({
    required this.id,
    required this.username,
    required this.fullName,
    required this.licenceNumber,
    required this.role,
    required this.status,
    required this.statusReason,
    required this.approvedAt,
    required this.createdAt,
    required this.publicKeyFingerprint,
    required this.activationExpiresAt,
  });

  final String id;
  final String username;
  final String fullName;

  /// Null when there is none (an empty one is read as none).
  final String? licenceNumber;
  final Role role;
  final AccountStatus status;

  /// Why the account is suspended, rejected or deleted; null otherwise.
  final String? statusReason;

  /// When it was approved, in UTC; null if never approved through the API
  /// (an officer or administrator created by an administrator, a seeded
  /// account).
  final DateTime? approvedAt;

  /// When the account was requested or created, in UTC.
  final DateTime createdAt;

  /// The registered device key's SHA-256 fingerprint, or null for none.
  final String? publicKeyFingerprint;

  /// For an invited account with a code: when the code stops working, in
  /// UTC. Null for every other account, and for an invited account whose
  /// code was erased after 5 wrong attempts.
  final DateTime? activationExpiresAt;

  bool get hasDeviceKey => publicKeyFingerprint != null;

  /// Reads one user from the admin view, or null if a field is missing, has
  /// the wrong type, or the role or status is not one this app knows.
  ///
  /// Never guesses, like AccountRequest.fromJson. Extra fields are ignored.
  static AdminAccount? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final username = json['username'];
    final fullName = json['fullName'];
    final role = json['role'];
    final status = json['status'];
    final createdAt = json['createdAt'];
    for (final value in [id, username, fullName, role, status, createdAt]) {
      if (value is! String || value.isEmpty) return null;
    }

    // The optional ones: absent, null or a string; anything else is broken.
    final optional = <String, String?>{};
    for (final field in const [
      'licenceNumber',
      'statusReason',
      'publicKeyFingerprint',
      'approvedAt',
      'activationExpiresAt',
    ]) {
      final value = json[field];
      if (value != null && value is! String) return null;
      final text = value as String?;
      optional[field] = (text == null || text.isEmpty) ? null : text;
    }

    final created = DateTime.tryParse(createdAt as String);
    if (created == null) return null;
    final (approvedOk, approvedAt) = _time(optional['approvedAt']);
    final (expiresOk, expiresAt) = _time(optional['activationExpiresAt']);
    if (!approvedOk || !expiresOk) return null;

    final parsedRole = _byName(Role.values, role as String);
    final parsedStatus = _byName(AccountStatus.values, status as String);
    if (parsedRole == null || parsedStatus == null) return null;

    return AdminAccount(
      id: id as String,
      username: username as String,
      fullName: fullName as String,
      licenceNumber: optional['licenceNumber'],
      role: parsedRole,
      status: parsedStatus,
      statusReason: optional['statusReason'],
      approvedAt: approvedAt,
      createdAt: created.toUtc(),
      publicKeyFingerprint: optional['publicKeyFingerprint'],
      activationExpiresAt: expiresAt,
    );
  }

  /// (true, null) for no time, (true, time) for a good one, (false, null)
  /// for text that is not a time.
  static (bool, DateTime?) _time(String? text) {
    if (text == null) return (true, null);
    final parsed = DateTime.tryParse(text);
    return parsed == null ? (false, null) : (true, parsed.toUtc());
  }

  static T? _byName<T extends Enum>(List<T> values, String name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  // Only the role and status: a name, username, licence number or reason in
  // a log or crash report would be someone's personal details.
  @override
  String toString() =>
      'AdminAccount(role: ${role.name}, status: ${status.name})';
}

/// One page of accounts with one status.
class AdminAccountsPage {
  const AdminAccountsPage({required this.accounts, required this.total});

  final List<AdminAccount> accounts;

  /// How many accounts have this status in all, not only on this page.
  final int total;

  @override
  String toString() =>
      'AdminAccountsPage(accounts: ${accounts.length}, total: $total)';
}

/// An activation code, as POST /admin/users and /activation-code give it.
///
/// SECURITY: the code is shown once and never stored (api.md: "only its
/// SHA-256 hash is stored"). It lives only in the code page's state, and
/// toString() leaves it out, so it can never reach a log line.
class ActivationCode {
  const ActivationCode({required this.code, required this.expiresAt});

  /// For example "7KQ4-M2XD-9TNE", exactly as the server sent it.
  final String code;

  /// When it stops working, in UTC.
  final DateTime expiresAt;

  /// Reads `activation`, or null if it is unreadable.
  static ActivationCode? fromJson(Object? json) {
    if (json is! Map) return null;
    final code = json['code'];
    final expiresAt = json['expiresAt'];
    if (code is! String || code.trim().isEmpty || expiresAt is! String) {
      return null;
    }
    final expires = DateTime.tryParse(expiresAt);
    if (expires == null) return null;
    return ActivationCode(code: code, expiresAt: expires.toUtc());
  }

  @override
  String toString() => 'ActivationCode(code: hidden)';
}

/// The answer to creating an account or issuing a new code: the invited
/// account and its code.
class InvitedAccount {
  const InvitedAccount({required this.account, required this.activation});

  final AdminAccount account;
  final ActivationCode activation;

  @override
  String toString() => 'InvitedAccount($account, $activation)';
}
