// The name the server gives a device key (signing spec, section 2): "the
// lower-case hex SHA-256 of its SPKI DER bytes, 64 characters". Every user
// the API returns carries it as `publicKeyFingerprint`, and comparing it with
// this phone's own key's fingerprint tells the app whether this phone is the
// registered one.
//
// Plain Dart: package crypto is pure Dart, with no Flutter in it.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The fingerprint of the 91-byte SPKI public key [spki], for example
/// `4d61912d42cf...` (64 lower-case hex characters).
///
/// Digest.toString() writes lower-case hex, which is exactly the server's
/// form (backend signatureService.spkiFingerprint, Node's digest('hex')).
String keyFingerprint(Uint8List spki) => sha256.convert(spki).toString();

/// The first 8 characters, for showing on screen: enough for a person to
/// compare with what an administrator sees, short enough to read out.
String shortFingerprint(String fingerprint) =>
    fingerprint.length <= 8 ? fingerprint : fingerprint.substring(0, 8);
