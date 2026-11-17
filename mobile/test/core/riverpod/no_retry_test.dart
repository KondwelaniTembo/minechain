// Proves that noRetry really stops Riverpod from running a failed provider
// again, and that the test itself could see a retry if one happened.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/riverpod/no_retry.dart';

void main() {
  // Riverpod's default first retry comes after 200 ms and the second after a
  // further 400 ms, so after 500 ms the default would have run the provider
  // twice. Waiting that long is enough to see a retry if one is going to happen.
  const waitLongerThanFirstRetry = Duration(milliseconds: 500);

  // Builds a provider that always fails and counts how often it runs.
  ({FutureProvider<int> provider, int Function() runs}) alwaysFailing() {
    var runs = 0;
    final provider = FutureProvider<int>((ref) async {
      runs++;
      throw Exception('always fails');
    });
    return (provider: provider, runs: () => runs);
  }

  test('with noRetry, a failing provider runs exactly once', () async {
    final failing = alwaysFailing();
    // ProviderContainer is Riverpod without any widgets: the same store that
    // ProviderScope makes, usable in a plain test. `.test` disposes it at the
    // end of the test by itself.
    final container = ProviderContainer.test(retry: noRetry);

    // Listening keeps the provider active, as a screen showing it would. A
    // provider nobody listens to might wait instead of retrying, which would
    // make this test pass for the wrong reason.
    container.listen(failing.provider, (_, _) {});

    await Future<void>.delayed(waitLongerThanFirstRetry);

    expect(failing.runs(), 1);
    expect(container.read(failing.provider).hasError, isTrue);
  });

  test('without noRetry, the same provider is retried (control)', () async {
    // If this ever stops passing, Riverpod's default has changed and the test
    // above no longer proves anything; re-read no_retry.dart's notes.
    final failing = alwaysFailing();
    final container = ProviderContainer.test();
    container.listen(failing.provider, (_, _) {});

    await Future<void>.delayed(waitLongerThanFirstRetry);

    expect(failing.runs(), greaterThanOrEqualTo(2));
  });
}
