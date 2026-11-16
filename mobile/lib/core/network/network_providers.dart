// Riverpod providers for the network layer.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../config/config_provider.dart';
import 'api_client.dart';
import 'pinned_http_client.dart';
import 'pinned_roots.dart';
import 'session_events.dart';

/// The app's one HTTP client, pinned to the three bundled roots, TLS 1.3 only.
///
/// A FutureProvider because loading the certificate files takes a moment. It is
/// built once and reused (a client keeps connections open for reuse, which
/// saves a TLS handshake per request on a slow network), and closed when the
/// app's ProviderScope goes away.
final pinnedHttpClientProvider = FutureProvider<http.Client>((ref) async {
  final roots = await loadPinnedRoots();
  final client = buildPinnedClient(roots);
  ref.onDispose(client.close);
  return client;
});

/// The app's one SessionEvents. Auth (F6-F8) listens to it; ApiClient reports
/// to it.
final sessionEventsProvider = Provider<SessionEvents>((ref) {
  final events = SessionEvents();
  ref.onDispose(events.dispose);
  return events;
});

/// The API client.
///
/// Why a FutureProvider, like the HTTP client under it: the alternative was to
/// load the certificate files in main() before runApp, so everything could be
/// synchronous. But every use of the API is awaited anyway, so
/// `await ref.read(apiClientProvider.future)` costs callers nothing, the files
/// are still loaded only once (the result is kept), and main() stays as small
/// as it is. If a certificate file were missing, the future fails with a
/// PinningSetupError, and the first caller turns that into "the connection is
/// not safe" (see ServerStatusController.check): the app still connects to
/// nothing, so it stays fail-closed.
final apiClientProvider = FutureProvider<ApiClient>((ref) async {
  final client = await ref.watch(pinnedHttpClientProvider.future);
  return ApiClient(
    client: client,
    baseUri: ref.watch(appConfigProvider).apiBaseUri,
    sessionEvents: ref.watch(sessionEventsProvider),
  );
});
