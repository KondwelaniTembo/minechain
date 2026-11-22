// The one place that talks HTTP to the MineChain API (plan sections 3.2, 4.3
// and 5).
//
// Everything above it (repositories, from F6) calls methods like
// `api.get(['auth', 'me'], token: t)` and gets back either decoded JSON or an
// AppFailure. Nothing above it ever sees a socket, a status code or a header.
// The one exception is [ApiClient.getFile] (reports plan, T1): a report is a
// file, so its caller gets the bytes and the checked filename, still never a
// header.
//
// SECURITY rules this file keeps:
// - the token goes only in the Authorization header, never in the address;
// - nothing is logged (no request or response bodies, tokens, query strings,
//   or addresses), and no failure carries any of them;
// - redirects are not followed: the API never redirects, and following one
//   could carry the request (and its token) somewhere unexpected;
// - every exception is turned into an AppFailure; none escapes raw.
//
// Plain Dart (no Flutter), so it is tested with package http's MockClient.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../errors/app_failure.dart';
import 'session_events.dart';

/// Waits [duration]. Injected so tests can decide when "time is up" without
/// actually waiting.
typedef Delay = Future<void> Function(Duration duration);

/// The real [Delay].
Future<void> realDelay(Duration duration) => Future<void>.delayed(duration);

/// Sends requests to the API and turns the answers into JSON or AppFailures.
class ApiClient {
  // `this._client` stores the argument straight into the private field; the
  // caller still writes `client:` (Dart drops the underscore for the name).
  ApiClient({
    required this._client,
    required this._baseUri,
    required this._sessionEvents,
    this.defaultTimeout = const Duration(seconds: 30),
    this._delay = realDelay,
  });

  final http.Client _client;
  final Uri _baseUri;
  final SessionEvents _sessionEvents;
  final Delay _delay;

  /// How long a request may take in total unless the call says otherwise
  /// (plan section 5.4).
  final Duration defaultTimeout;

  /// GET [path]. See [_send] for the parameters.
  Future<Object?> get(
    List<String> path, {
    Map<String, String>? query,
    String? token,
    Duration? timeout,
    bool expectBody = true,
  }) => _send(
    'GET',
    path,
    query: query,
    token: token,
    timeout: timeout,
    expectBody: expectBody,
  );

  /// POST [path] with [body] as JSON.
  Future<Object?> post(
    List<String> path, {
    Object? body,
    Map<String, String>? query,
    String? token,
    Duration? timeout,
    bool expectBody = true,
  }) => _send(
    'POST',
    path,
    body: body,
    query: query,
    token: token,
    timeout: timeout,
    expectBody: expectBody,
  );

  /// PUT [path] with [body] as JSON.
  Future<Object?> put(
    List<String> path, {
    Object? body,
    Map<String, String>? query,
    String? token,
    Duration? timeout,
    bool expectBody = true,
  }) => _send(
    'PUT',
    path,
    body: body,
    query: query,
    token: token,
    timeout: timeout,
    expectBody: expectBody,
  );

  /// GET [path] for a file of [mediaType] (for example `text/csv`), not JSON.
  ///
  /// Sends `Accept: <mediaType>`. A 2xx answer must say it is [mediaType] and
  /// have a body, or it is a [BadResponse]: an HTML page with status 200 must
  /// never be saved as a report. Refusals are still the API's JSON error
  /// format, so they become the same AppFailures as for [get], with the same
  /// session events.
  Future<DownloadedFile> getFile(
    List<String> path, {
    required String mediaType,
    Map<String, String>? query,
    String? token,
    Duration? timeout,
  }) async {
    final response = await _exchange(
      'GET',
      path,
      query: query,
      token: token,
      timeout: timeout,
      accept: mediaType,
    );
    final status = response.statusCode;
    if (response.bodyBytes.isEmpty ||
        _mediaTypeOf(response.headers['content-type']) !=
            mediaType.toLowerCase()) {
      throw BadResponse(status: status);
    }
    return DownloadedFile(
      bytes: response.bodyBytes,
      filename: _filenameFrom(response.headers['content-disposition']),
    );
  }

  /// Sends one request and decodes its JSON answer.
  ///
  /// - [path]: the path as separate pieces, for example
  ///   `['consignments', 'by-qr', qrCode]`. Each piece is encoded on its own,
  ///   so a "/" inside a QR code is sent as %2F and cannot change the path.
  /// - [query]: query parameters, encoded the same way.
  /// - [body]: any value jsonEncode accepts; sent as JSON.
  /// - [token]: the login token, sent as `Authorization: Bearer <token>`.
  /// - [timeout]: the whole request's time limit; [defaultTimeout] if null.
  /// - [expectBody]: if false, a successful answer may be empty (returns null).
  ///
  /// Returns the decoded JSON of a 2xx answer. Throws an [AppFailure]
  /// otherwise.
  Future<Object?> _send(
    String method,
    List<String> path, {
    Object? body,
    Map<String, String>? query,
    String? token,
    Duration? timeout,
    required bool expectBody,
  }) async {
    final response = await _exchange(
      method,
      path,
      body: body,
      query: query,
      token: token,
      timeout: timeout,
      accept: 'application/json',
    );
    return _decodeSuccess(response, expectBody: expectBody);
  }

  /// Sends one request and returns its 2xx answer, for [_send] and
  /// [getFile]. Every other answer, and every exception, is thrown as an
  /// [AppFailure], after announcing a session-ending refusal.
  Future<http.Response> _exchange(
    String method,
    List<String> path, {
    Object? body,
    Map<String, String>? query,
    String? token,
    Duration? timeout,
    required String accept,
  }) async {
    final uri = _baseUri.replace(
      pathSegments: path,
      // null (not an empty map) so no stray "?" is added.
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );

    // An AbortableRequest is really cancelled when abortTrigger completes:
    // package http closes the connection (F4 notes). The trigger is "the time
    // limit has passed".
    final request =
        http.AbortableRequest(
            method,
            uri,
            abortTrigger: _delay(timeout ?? defaultTimeout),
          )
          ..followRedirects = false
          ..headers['accept'] = accept;
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      // send() returns once the headers arrive; fromStream reads the body.
      // Both can fail, so both are inside the try.
      response = await http.Response.fromStream(await _client.send(request));
    } on TlsException {
      // Checked first. HandshakeException is a TlsException: the chain did not
      // end at a pinned root, or the server could not do TLS 1.3. package http
      // passes these through unchanged.
      throw const InsecureConnection();
    } on SocketException {
      // No network, name lookup failed, connection refused or the 15 s
      // connection timeout. package http wraps these in a ClientException
      // that still is a SocketException, so this catches both.
      throw const NoConnection();
    } on http.RequestAbortedException {
      // Our time limit passed. It is a ClientException, so it must be caught
      // before the general case below.
      throw const TimedOut();
    } on http.ClientException {
      // Any other ClientException comes from dart:io's HttpException, which
      // package http converts: for example "Connection closed before full
      // header was received". The connection broke part-way, which for the
      // user is the same as having no connection, and retrying later is the
      // right advice. There was no complete answer, so BadResponse (which
      // needs a status) would be wrong.
      throw const NoConnection();
    } on Exception {
      // Anything else from the network stack. Programming mistakes (Error,
      // not Exception) are not caught here, so they still fail loudly in
      // tests instead of hiding as "no connection".
      throw const NoConnection();
    }

    final status = response.statusCode;
    if (status >= 200 && status < 300) return response;

    final failure = _refusalFrom(response);
    // Only a request that carried a token can have its session refused. A 401
    // at login (INVALID_CREDENTIALS) is just a wrong password.
    if (token != null &&
        failure is ServerRefused &&
        SessionEvents.endsSession(failure.status, failure.code)) {
      _sessionEvents.report(failure.code);
    }
    throw failure;
  }

  /// The decoded JSON of a successful answer.
  static Object? _decodeSuccess(
    http.Response response, {
    required bool expectBody,
  }) {
    if (response.bodyBytes.isEmpty) {
      if (expectBody) throw BadResponse(status: response.statusCode);
      return null;
    }
    try {
      // Decoded as UTF-8 from the bytes. response.body would guess the
      // character set from the headers and fall back to Latin-1.
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      // Not UTF-8, or not JSON: for example an HTML page with status 200.
      throw BadResponse(status: response.statusCode);
    }
  }

  /// A ServerRefused if the answer is the API's error format, else a
  /// BadResponse.
  static AppFailure _refusalFrom(http.Response response) {
    final status = response.statusCode;
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map && json['error'] is Map) {
        final error = json['error'] as Map;
        final code = error['code'];
        final message = error['message'];
        if (code is String && code.isNotEmpty && message is String) {
          return ServerRefused(
            status: status,
            code: code,
            serverMessage: message,
            details: _detailsFrom(error['details']),
            retryAfter: _retryAfterFrom(response.headers['retry-after']),
          );
        }
      }
    } on FormatException {
      // Falls through: HTML from Cloudflare, an empty body, broken JSON.
    }
    return BadResponse(status: status);
  }

  /// The media type of a Content-Type header in lower case, without its
  /// parameters: `text/csv; charset=utf-8` gives `text/csv`.
  static String? _mediaTypeOf(String? header) =>
      header?.split(';').first.trim().toLowerCase();

  /// The filename of a `Content-Disposition: attachment; filename="..."`
  /// header, or null.
  ///
  /// Only the API's own filename form is accepted (api.md, "The file"):
  /// lower-case letters, digits, `.` and `-`, not starting with a dot. Such
  /// a name has no `/`, `\` or `..` that could reach outside a folder, so
  /// it is safe to write a file under. Anything else gives null and the
  /// caller picks its own name.
  static String? _filenameFrom(String? header) {
    if (header == null) return null;
    final match = RegExp(
      r'^attachment;\s*filename="([a-z0-9][a-z0-9.-]{0,119})"$',
    ).firstMatch(header.trim());
    final name = match?.group(1);
    if (name == null || name.contains('..')) return null;
    return name;
  }

  /// A `Retry-After` of whole seconds (the form express-rate-limit sends).
  /// The other allowed form, an HTTP date, is not used by this API and gives
  /// null, as does anything odd: the caller then picks its own wait.
  static Duration? _retryAfterFrom(String? header) {
    if (header == null || !RegExp(r'^[0-9]{1,6}$').hasMatch(header.trim())) {
      return null;
    }
    return Duration(seconds: int.parse(header.trim()));
  }

  /// The `details` list, keeping only well-formed entries. A missing or odd
  /// list gives no details; it does not spoil an otherwise valid refusal.
  static List<FieldProblem> _detailsFrom(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map &&
            entry['field'] is String &&
            entry['message'] is String)
          FieldProblem(
            field: entry['field'] as String,
            message: entry['message'] as String,
            code: entry['code'] is String ? entry['code'] as String : null,
          ),
    ];
  }
}

/// A file from [ApiClient.getFile].
class DownloadedFile {
  const DownloadedFile({required this.bytes, required this.filename});

  /// The body exactly as received.
  final Uint8List bytes;

  /// The server's filename if it had the API's safe form, else null.
  final String? filename;

  /// No bytes and no name: a report holds people's usernames and places.
  @override
  String toString() => 'DownloadedFile(${bytes.length} bytes)';
}
