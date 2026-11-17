// Turns off Riverpod's automatic retry, everywhere in the app.
//
// Why: Riverpod 3 re-runs a provider that failed, by itself, up to 10 times
// with growing waits (200 ms, 400 ms, ... up to 6.4 s). See
// `ProviderContainer.defaultRetry` in riverpod 3.5.0,
// lib/src/core/provider_container.dart. It skips only programming errors
// (`Error`); an `Exception`, which is what a refused or failed request will be,
// would be retried.
//
// For this app that is wrong (plan section 3.1):
// - a login, a password change or a sync must never be sent again behind the
//   user's back;
// - a refused request repeated 10 times uses up the server's rate limits, for
//   example the 10 failed logins per username in 15 minutes.
// Trying again is the user's choice, through a "Try again" button.
//
// How: `ProviderScope(retry: ...)` and `ProviderContainer(retry: ...)` both take
// a function `Duration? Function(int retryCount, Object error)`. Riverpod calls
// it after each failure: a Duration means "wait this long, then run the
// provider again", and null means "do not retry". This one always says null.
//
// main.dart and the tests both pass this same function, so the app and its
// tests cannot drift apart. A single provider could still set its own `retry:`
// (the provider's own setting wins over the container's), so none should,
// unless a later decision says so.
//
// Riverpod names this function type `Retry`, but marks that name @internal,
// so we write the signature out instead of using the name.

/// Never retries: always returns null, whatever the failure.
///
/// Pass it as `retry: noRetry` to every `ProviderScope` and `ProviderContainer`.
Duration? noRetry(int retryCount, Object error) => null;
