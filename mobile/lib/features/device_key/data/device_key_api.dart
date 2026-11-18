// PUT /auth/me/public-key, as docs/api.md documents it:
//
//   Login needed: miner, transporter or buyer. Officers and administrators
//   get 403 FORBIDDEN. Rate limits: none yet.
//   Body: { "publicKey": SPKI DER in standard base64 with padding, exactly
//           91 bytes, which is 124 characters }. Any other field is refused.
//   200, "both the first time and when the same key is sent again":
//     { "user": { ..., "publicKeyFingerprint": "<64 hex>" } }
//   400 VALIDATION_FAILED, 400 INVALID_PUBLIC_KEY,
//   409 PUBLIC_KEY_ALREADY_REGISTERED ("This account already has a different
//       key"), 409 PUBLIC_KEY_IN_USE ("Another account already has this key"),
//   plus the token errors (401) and account errors (403).
//
// This file only sends the request and reads the answer. What each answer
// means for this phone is the controller's job.

import 'dart:convert';
import 'dart:typed_data';

import '../../../core/errors/app_failure.dart';
import '../../../core/network/api_client.dart';
import '../../auth/domain/user.dart';

class DeviceKeyApi {
  DeviceKeyApi(this._api);

  final ApiClient _api;

  /// Registers [spki] as the logged-in account's device key and returns the
  /// account as the server now has it. Throws an AppFailure if refused.
  ///
  /// base64.encode is standard base64 with `=` padding and no line breaks,
  /// which is the only form the server accepts (signing spec, section 2).
  Future<UserParseResult> register({
    required String token,
    required Uint8List spki,
  }) async {
    final json = await _api.put(
      const ['auth', 'me', 'public-key'],
      body: {'publicKey': base64.encode(spki)},
      token: token,
    );
    if (json is! Map) throw const BadResponse(status: 200);
    return User.fromJson(json['user']);
  }
}
