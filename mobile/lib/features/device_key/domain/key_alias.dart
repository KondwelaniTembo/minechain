// The Keystore name ("alias") of a user's signing key (decision Mobile (17)).
//
// One key per user, not one per phone: the server lets a key belong to one
// account only (PUBLIC_KEY_IN_USE), so two people who share a phone each need
// their own key. Putting the user id in the alias gives each of them one.
//
// Plain Dart, no Flutter: this is a business rule, and the Kotlin side checks
// the same pattern again (DeviceKeyPlugin.kt), so neither side relies on the
// other alone.

/// The fixed start of every MineChain signing key alias.
const String deviceKeyAliasPrefix = 'minechain_signing_';

/// A user id as the server issues it: a lower-case UUID (signing spec,
/// section 4, "actor_id ... always lower case").
final RegExp _lowerCaseUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// The alias of [userId]'s signing key, for example
/// `minechain_signing_3f2b6c1e-0000-4000-8000-000000000001`.
///
/// Throws [ArgumentError] for anything that is not a lower-case UUID. Upper
/// case is refused rather than folded: a folded id would name a different
/// key from the one made under the server's spelling. The id itself is left
/// out of the error message.
String deviceKeyAlias(String userId) {
  if (!_lowerCaseUuid.hasMatch(userId)) {
    throw ArgumentError('userId must be a lower-case UUID');
  }
  return '$deviceKeyAliasPrefix$userId';
}
