// Manual check of the app's TLS settings against real servers (plan section
// 9.2). Run it on the laptop, from mobile/:
//
//   dart run tool/check_tls.dart              (reads env/api.json)
//   dart run tool/check_tls.dart <API origin> (an https origin given directly)
//
// It uses the very same code as the app (lib/core/network/
// pinned_http_client.dart), with the certificate files read from disk. It
// needs the network, so it is a tool you run by hand, not a test.
//
// The API's address is never printed: "API" is shown in its place.
//
// Checks:
//   (a) pinned + TLS 1.3 -> GET API /health succeeds.
//   (b) pinned + TLS 1.3 -> a site whose chain ends at another CA's root is
//       refused at the handshake, because of its certificate.
//   (c) the TLS 1.3 minimum on its own, with the laptop's normal roots, so
//       pinning plays no part: a TLS 1.2-only server is refused with a 1.3
//       minimum and accepted with a 1.2 minimum.
//   (d) the SHA-256 of each bundled root matches the value verified with
//       certutil (assets/certs/README.md).
// Each prints PASS or FAIL; the exit code is 1 if any fails.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:minechain/core/config/app_config.dart';
import 'package:minechain/core/network/pinned_http_client.dart';

/// (b): a public site whose certificate chain ends at a root we do NOT pin.
///
/// How we know: on 16 Nov 2026 `openssl s_client -showcerts` showed the chain
///   www.digicert.com <- DigiCert EV RSA CA G2 <- DigiCert Global Root G2
/// and DigiCert Global Root G2 is none of GTS Root R4, GlobalSign ECC Root CA -
/// R4 or ISRG Root X1. The same probe showed it speaks TLS 1.3, so a refusal
/// can only come from the certificate, not from the version. The check also
/// confirms this at run time: it passes only if the certificate itself was
/// rejected (see `rejectedCertificate` below). DigiCert is a CA, so its own
/// site is unlikely ever to use another CA's certificate.
const otherRootHost = 'www.digicert.com';

/// (c): a public server that offers only TLS 1.2: badssl.com's test host.
///
/// How we know: on 16 Nov 2026 `openssl s_client -tls1_3` against it was
/// refused with "handshake failure" (alert 40), and `-tls1_2` connected, with a
/// valid certificate (Let's Encrypt, until 28 Dec 2026). Port 1012 is the one
/// badssl.com lists for this host.
const tls12OnlyHost = 'tls-v1-2.badssl.com';
const tls12OnlyPort = 1012;

/// (d): the fingerprints verified with Windows certutil on 16 Nov 2026 01:28
/// against the CAs' published values (assets/certs/README.md).
const verifiedFingerprints = {
  'assets/certs/gts_root_r4.pem':
      '349dfa4058c5e263123b398ae795573c4e1313c83fe68f93556cd5e8031b3c7d',
  'assets/certs/globalsign_ecc_root_r4.pem':
      'b085d70b964f191a73e4af0d54ae7a0e07aafdaf9b71dd0862138ab7325a24a2',
  'assets/certs/isrg_root_x1.pem':
      '96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6',
};

const healthTimeout = Duration(seconds: 90);

var _failures = 0;

void report(String check, bool passed, String detail) {
  if (!passed) _failures++;
  stdout.writeln('${passed ? 'PASS' : 'FAIL'}  $check: $detail');
}

Future<void> main(List<String> args) async {
  final api = _readApiOrigin(args);
  final roots = [for (final f in pinnedRootFiles) File(f).readAsBytesSync()];
  final pinned = buildPinnedContext(roots);

  checkFingerprints(roots); // (d) first: it needs no network
  await checkApiHealth(pinned, api); // (a)
  await checkOtherRootRefused(pinned); // (b)
  await checkTls13Minimum(); // (c)

  stdout.writeln(_failures == 0
      ? '\nAll checks passed.'
      : '\n$_failures check(s) failed.');
  exit(_failures == 0 ? 0 : 1);
}

// ---- (d) ------------------------------------------------------------------

void checkFingerprints(List<List<int>> roots) {
  for (var i = 0; i < pinnedRootFiles.length; i++) {
    final file = pinnedRootFiles[i];
    final actual = sha256.convert(derOfPem(roots[i])).toString();
    final expected = verifiedFingerprints[file];
    report('(d) fingerprint', actual == expected, '$file  $actual');
  }
}

// ---- (a) ------------------------------------------------------------------

Future<void> checkApiHealth(SecurityContext pinned, Uri api) async {
  final client = IOClient(buildPinnedHttpClient(pinned));
  try {
    final request = http.AbortableRequest(
      'GET',
      api.replace(path: '/health'),
      abortTrigger: Future<void>.delayed(healthTimeout),
    );
    stdout.writeln('      (a) calling API /health; after the server has been '
        'idle this can take a minute...');
    final response = await http.Response.fromStream(await client.send(request));
    final ok = response.statusCode == 200 && _bodySaysOk(response.body);
    // Only the status is printed, never the body.
    report('(a) pinned GET API /health', ok, 'status ${response.statusCode}');
  } catch (e) {
    // Only the kind of error: its message could contain the address.
    report('(a) pinned GET API /health', false, 'failed with ${e.runtimeType}');
  } finally {
    client.close();
  }
}

// ---- (b) ------------------------------------------------------------------

Future<void> checkOtherRootRefused(SecurityContext pinned) async {
  // 1. The real check: the app's client must refuse the site.
  final client = IOClient(buildPinnedHttpClient(pinned));
  Object? error;
  try {
    await client.get(Uri.https(otherRootHost, '/'));
  } catch (e) {
    error = e;
  } finally {
    client.close();
  }

  // 2. Why it was refused. A raw TLS connection with the same context, where
  // onBadCertificate is told about the certificate that failed verification.
  // It returns false, so the connection is still refused (fail closed); we
  // only record what was seen. If it is never called, the refusal had another
  // cause and the check does not count.
  final rejected = await rejectedCertificate(pinned, otherRootHost, 443);

  final passed = error is HandshakeException && rejected != null;
  report(
    '(b) pinned refuses $otherRootHost',
    passed,
    error == null
        ? 'it was ACCEPTED, so pinning is not working'
        : '${error.runtimeType}; rejected certificate: '
            '${rejected == null ? 'none seen' : 'subject ${rejected.subject}, issued by ${rejected.issuer}'}',
  );
}

/// The certificate the TLS layer rejected when connecting to [host] with
/// [context], or null if none was rejected.
Future<X509Certificate?> rejectedCertificate(
  SecurityContext context,
  String host,
  int port,
) async {
  X509Certificate? seen;
  try {
    final socket = await SecureSocket.connect(
      host,
      port,
      context: context,
      timeout: connectionTimeout,
      onBadCertificate: (certificate) {
        seen = certificate;
        return false; // still refuse it
      },
    );
    await socket.close();
  } on IOException {
    // Expected: the handshake fails.
  }
  return seen;
}

// ---- (c) ------------------------------------------------------------------

Future<void> checkTls13Minimum() async {
  final url = Uri.https('$tls12OnlyHost:$tls12OnlyPort', '/');

  // The laptop's normal roots (withTrustedRoots: true), which trust badssl's
  // Let's Encrypt certificate, so pinning plays no part here. The HttpClient is
  // built by the same function the app uses.
  SecurityContext systemRoots(TlsProtocolVersion minimum) =>
      SecurityContext(withTrustedRoots: true)
        ..minimumTlsProtocolVersion = minimum;

  // With a 1.3 minimum: must be refused at the handshake, and not because of
  // the certificate (that would prove nothing about the version).
  final strict = systemRoots(TlsProtocolVersion.tls1_3);
  Object? strictError;
  final strictClient = IOClient(buildPinnedHttpClient(strict));
  try {
    await strictClient.get(url);
  } catch (e) {
    strictError = e;
  } finally {
    strictClient.close();
  }
  final certBlamed =
      await rejectedCertificate(strict, tls12OnlyHost, tls12OnlyPort);
  report(
    '(c) minimum TLS 1.3 refuses $tls12OnlyHost',
    strictError is HandshakeException && certBlamed == null,
    strictError == null
        ? 'it was ACCEPTED, so the minimum is not working'
        : certBlamed != null
            ? 'refused, but for its certificate, so this proves nothing'
            : '${strictError.runtimeType} (version refused)',
  );

  // With a 1.2 minimum: the same server must work, which shows the refusal
  // above was the version and that the test server is still there.
  final relaxedClient = IOClient(
    buildPinnedHttpClient(systemRoots(TlsProtocolVersion.tls1_2)),
  );
  try {
    final response = await relaxedClient.get(url);
    report('(c) minimum TLS 1.2 accepts $tls12OnlyHost', true,
        'status ${response.statusCode}');
  } catch (e) {
    report(
      '(c) minimum TLS 1.2 accepts $tls12OnlyHost',
      false,
      '$e\n      If this is a certificate error, Dart could not use this '
          "laptop's root store, or the test host's certificate has lapsed; "
          'if it cannot connect, the test host may be gone. Either way the '
          'TLS 1.3 refusal above is not proven.',
    );
  } finally {
    relaxedClient.close();
  }
}

// ---- helpers --------------------------------------------------------------

/// The API origin from the argument or env/api.json, checked with the app's
/// own rules. Exits with a message (never the value) if it is unusable.
Uri _readApiOrigin(List<String> args) {
  String raw;
  if (args.isNotEmpty) {
    raw = args.first;
  } else {
    final file = File('env/api.json');
    if (!file.existsSync()) {
      _stop('env/api.json not found. Run from mobile/, and create it as '
          'described in lib/core/config/app_config.dart, or pass the API '
          'origin as an argument.');
    }
    final json = jsonDecode(file.readAsStringSync());
    raw = (json is Map && json['API_BASE_URL'] is String)
        ? json['API_BASE_URL'] as String
        : '';
  }

  return switch (AppConfig.check(raw)) {
    ConfigOk(:final config) => config.apiBaseUri,
    ConfigInvalid(:final problem) =>
      _stop('The API address was refused: ${problem.name}.'),
  };
}

/// Prints [message] and ends the tool with exit code 2 (could not run).
/// `Never` tells Dart this function does not return.
Never _stop(String message) {
  stderr.writeln(message);
  exit(2);
}

bool _bodySaysOk(String body) {
  try {
    final json = jsonDecode(body);
    return json is Map && json['status'] == 'ok';
  } on FormatException {
    return false;
  }
}
