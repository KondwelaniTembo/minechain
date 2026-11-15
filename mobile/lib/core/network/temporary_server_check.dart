// TEMPORARY (F4): one GET /health through the pinned client, for the "Check
// server" tile on the sample home. Replaced in F5 by the API client and
// ServerStatusController (plan section 5.5), which turn every failure into an
// AppFailure.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// What the check found.
enum ServerCheck { ready, insecure, noConnection, timedOut, other }

/// How long to wait for /health in total: Render's free service can take
/// 50-60 s to wake after 15 minutes idle (plan section 5.4).
const Duration healthTimeout = Duration(seconds: 90);

/// Calls GET [healthUri] with [client] and says what happened.
///
/// Logs nothing: not the address, not the answer.
Future<ServerCheck> checkServerHealth(http.Client client, Uri healthUri) async {
  try {
    // An AbortableRequest is cancelled for real when its abortTrigger
    // completes: the connection is closed, not just ignored (package http
    // 1.6.0, lib/src/io_client.dart). Here the trigger is a 90 s timer.
    final request = http.AbortableRequest(
      'GET',
      healthUri,
      abortTrigger: Future<void>.delayed(healthTimeout),
    );
    final response = await http.Response.fromStream(await client.send(request));

    if (response.statusCode == 200 && _saysOk(response.body)) {
      return ServerCheck.ready;
    }
    return ServerCheck.other;
  } on http.RequestAbortedException {
    return ServerCheck.timedOut;
  } on TlsException {
    // HandshakeException is a TlsException: the chain did not end at a pinned
    // root, or the server could not do TLS 1.3. Checked before
    // SocketException, because package http passes TLS errors through as they
    // are.
    return ServerCheck.insecure;
  } on SocketException {
    // No network, the name could not be looked up, or the 15 s connection
    // timeout. package http wraps these in a ClientException that still is a
    // SocketException.
    return ServerCheck.noConnection;
  } catch (_) {
    return ServerCheck.other;
  }
}

bool _saysOk(String body) {
  try {
    final json = jsonDecode(body);
    return json is Map && json['status'] == 'ok';
  } on FormatException {
    return false;
  }
}
