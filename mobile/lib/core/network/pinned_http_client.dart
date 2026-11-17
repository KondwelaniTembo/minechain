// The app's only way to make HTTPS connections: trusts three bundled root
// certificates and nothing else, and refuses anything below TLS 1.3
// (plan sections 5.2-5.4; decisions Mobile (2) and Deployment (11)).
//
// Plain Dart (dart:io and package:http, no Flutter), so tool/check_tls.dart
// runs exactly this code on the laptop. The app loads the certificate files
// with Flutter's asset bundle (pinned_roots.dart); the tool reads them from
// disk; both hand the bytes to the functions below.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// The pinned roots, as paths inside mobile/. The same strings are the asset
/// keys in pubspec.yaml, so the app and the tool use one list.
const List<String> pinnedRootFiles = [
  'assets/certs/gts_root_r4.pem',
  'assets/certs/globalsign_ecc_root_r4.pem',
  'assets/certs/isrg_root_x1.pem',
];

/// How long to wait for a connection to be made (TCP and the TLS handshake).
/// The connection goes to Cloudflare, which answers fast even while Render is
/// asleep; 15 s leaves room for slow 3G (plan section 5.4).
const Duration connectionTimeout = Duration(seconds: 15);

/// How long an unused kept-alive connection stays open. Short, so connections
/// do not linger on a mobile network that may have changed.
const Duration idleTimeout = Duration(seconds: 15);

/// Thrown when the pinned roots cannot be set up. This is a fault in how the
/// app was built (a missing or broken certificate file), not a network
/// problem, so it is an [Error]: it should stop the app's networking, not be
/// handled and retried.
final class PinningSetupError extends Error {
  PinningSetupError(this.message);
  final String message;

  @override
  String toString() => 'PinningSetupError: $message';
}

/// Builds the TLS settings: trust exactly [pemRoots] and nothing else, and
/// require TLS 1.3.
///
/// Throws [PinningSetupError] if the list is empty or any entry is empty or not
/// a PEM certificate. It never quietly continues with fewer roots: with none, it
/// would trust nothing and every request would fail with a confusing error; and
/// it must never trust "everything" (the phone's store) instead.
SecurityContext buildPinnedContext(List<List<int>> pemRoots) {
  if (pemRoots.isEmpty) {
    throw PinningSetupError('no pinned root certificates were given');
  }

  // withTrustedRoots: false starts with an EMPTY trust store. With true, the
  // context would also trust every root on the phone, including any that a
  // user or an attacker installed, which is exactly what pinning prevents.
  final context = SecurityContext(withTrustedRoots: false);

  for (var i = 0; i < pemRoots.length; i++) {
    final pem = pemRoots[i];
    final which = 'pinned root ${i + 1} of ${pemRoots.length}';
    if (pem.isEmpty) throw PinningSetupError('$which is empty');
    // setTrustedCertificatesBytes would also accept other formats (DER,
    // PKCS12). We only ever ship PEM, so anything else means a wrong file.
    if (!_looksLikePem(pem)) {
      throw PinningSetupError('$which is not a PEM certificate');
    }
    try {
      // Adds this certificate to the trust store as a root.
      context.setTrustedCertificatesBytes(pem);
    } on Exception {
      // The details of the parser's complaint are not useful to a user and
      // could be long; the message says which file to look at.
      throw PinningSetupError('$which could not be read as a certificate');
    }
  }

  // The lowest TLS version this app accepts. A server (or a machine in the
  // middle) offering only TLS 1.2 or older makes the handshake fail, so a
  // downgrade cannot happen. Dart's default would be TLS 1.2. This is what
  // meets NFR-01, since the API itself cannot enforce TLS 1.3 (decisions,
  // 14 Nov limitation "TLS 1.3 is enforced at Render's edge").
  context.minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;

  return context;
}

/// A dart:io HttpClient that uses [context] for every connection.
HttpClient buildPinnedHttpClient(SecurityContext context) {
  // Deliberately NO badCertificateCallback. That callback is asked "should I
  // accept this certificate anyway?" when verification fails; leaving it unset
  // means the answer is always no, so a certificate that does not chain to a
  // pinned root fails the request. Setting it, even "just for testing", is
  // how pinning gets switched off by accident.
  return HttpClient(context: context)
    ..connectionTimeout = connectionTimeout
    ..idleTimeout = idleTimeout;
}

/// The pinned client the app uses: package http's [IOClient] around the
/// pinned [HttpClient], so the rest of the app gets http's simple API
/// (`client.get(uri)`) while every connection goes through our settings.
http.Client buildPinnedClient(List<List<int>> pemRoots) {
  return IOClient(buildPinnedHttpClient(buildPinnedContext(pemRoots)));
}

/// The DER bytes of a PEM certificate: the base64 text between the BEGIN and
/// END lines, decoded. Fingerprints (SHA-256) are taken over these bytes,
/// which is what certutil and crt.sh show.
Uint8List derOfPem(List<int> pemBytes) {
  final text = ascii.decode(pemBytes, allowInvalid: true);
  final match = RegExp(
    r'-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----',
  ).firstMatch(text);
  if (match == null) {
    throw PinningSetupError('not a PEM certificate');
  }
  final base64Body = match.group(1)!.replaceAll(RegExp(r'\s'), '');
  return base64.decode(base64Body);
}

bool _looksLikePem(List<int> bytes) =>
    ascii.decode(bytes, allowInvalid: true).contains('-----BEGIN CERTIFICATE-----');
