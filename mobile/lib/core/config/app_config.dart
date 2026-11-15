// The app's build-time settings: for now, only the API's address.
//
// ---------------------------------------------------------------------------
// How to create the real settings file (once, on each laptop):
//
//   1. In mobile/, copy the example:
//        Copy-Item env\api.example.json env\api.json
//   2. Open env/api.json and replace https://example.invalid with the API's
//      https address (the origin only: no path, no trailing words).
//   3. Run the app with it:
//        flutter run --dart-define-from-file=env/api.json
//
// env/api.json is git-ignored (mobile/.gitignore), so the address never enters
// the repository. Tests do not need it: they never read the real address.
// ---------------------------------------------------------------------------
//
// SECURITY: a --dart-define value is compiled into the app as plain text.
// Anyone with the APK can unzip it and read the value. So only values that are
// fine to be public may ever be given this way: the API's address is (the app
// talks to it openly), but a key, password, token or secret never is. The app
// holds no secrets of its own; the user's token arrives at run time, after
// login, and lives in secure storage.
//
// This file is plain Dart (no Flutter, no Riverpod), so the checks below can be
// unit-tested with any string, without building the app with a define.

/// The API address exactly as it was given at build time, or '' if none was.
///
/// `String.fromEnvironment` is a compile-time constant: the compiler replaces
/// it with the value from --dart-define(-from-file) while building, so it is
/// fixed inside the app and cannot change at run time. It must be called with
/// `const`. Only main.dart reads this; everything else gets the checked
/// [AppConfig] from `appConfigProvider`.
const String compiledApiBaseUrl = String.fromEnvironment('API_BASE_URL');

/// Checked settings the rest of the app uses.
class AppConfig {
  const AppConfig._(this.apiBaseUri);

  /// The API's origin: `https://host` or `https://host:port`, with no path and
  /// no trailing slash. Request paths are added to it, for example `/health`.
  final Uri apiBaseUri;

  /// Checks [raw] and returns either the settings or the reason it was refused.
  ///
  /// The reason is a fixed value, never the text that was given, so an error
  /// screen or a log line cannot repeat the address (or anything else that was
  /// typed into the settings file by mistake).
  static ConfigResult check(String raw) {
    // A stray space or new line in the JSON file is a typing slip, not a
    // different address, so it is removed before checking.
    final text = raw.trim();
    if (text.isEmpty) return const ConfigInvalid(ConfigProblem.missing);

    // tryParse returns null instead of throwing when the text is not a URL.
    final uri = Uri.tryParse(text);
    if (uri == null) return const ConfigInvalid(ConfigProblem.malformed);

    // Each check is one rule from plan section 5.1, in a fixed order, so the
    // same bad value always gives the same reason.
    if (uri.scheme != 'https') {
      // Also catches a value with no scheme at all, such as "api.example.org".
      return const ConfigInvalid(ConfigProblem.notHttps);
    }
    if (uri.userInfo.isNotEmpty) {
      // "https://name:password@host" would put a password in the app.
      return const ConfigInvalid(ConfigProblem.hasUserInfo);
    }
    if (uri.host.isEmpty) return const ConfigInvalid(ConfigProblem.missingHost);
    if (uri.path.isNotEmpty && uri.path != '/') {
      return const ConfigInvalid(ConfigProblem.hasPath);
    }
    // hasQuery is true even for a bare "?" with nothing after it.
    if (uri.hasQuery) return const ConfigInvalid(ConfigProblem.hasQuery);
    if (uri.hasFragment) return const ConfigInvalid(ConfigProblem.hasFragment);

    // Rebuild the origin from its parts, so "https://host/" and "https://host"
    // become the same value. Uri leaves out the port when it is https's
    // default (443).
    final origin = Uri(
      scheme: 'https',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
    return ConfigOk(AppConfig._(origin));
  }
}

/// Why an address was refused. Each name says what to fix in env/api.json.
enum ConfigProblem {
  missing,
  malformed,
  notHttps,
  hasUserInfo,
  missingHost,
  hasPath,
  hasQuery,
  hasFragment,
}

/// The result of [AppConfig.check]: exactly one of the two classes below.
///
/// `sealed` means no other kind can exist, so a `switch` over it that handles
/// both is complete, and the compiler says so (or complains if one is missing).
sealed class ConfigResult {
  const ConfigResult();
}

/// The address was accepted.
final class ConfigOk extends ConfigResult {
  const ConfigOk(this.config);
  final AppConfig config;
}

/// The address was refused, for [problem].
final class ConfigInvalid extends ConfigResult {
  const ConfigInvalid(this.problem);
  final ConfigProblem problem;

  @override
  String toString() => 'ConfigInvalid(${problem.name})';
}
