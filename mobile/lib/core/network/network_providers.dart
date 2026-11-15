// Riverpod providers for the network layer.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'pinned_http_client.dart';
import 'pinned_roots.dart';

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
