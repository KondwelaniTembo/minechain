// Sorts a refusal's `details` by field, so a form can show each message under
// the field it is about (plan section 3.2: VALIDATION_FAILED and WEAK_PASSWORD
// keep their details).
//
// Plain Dart: no Flutter, so it is tested on its own.

import 'app_failure.dart';

/// The details' messages keyed by field name (the API's names, for example
/// `username` or `password`). Several messages for one field (WEAK_PASSWORD
/// can list a few problems at once) are joined with line breaks, in the
/// server's order. A message repeated word for word is shown once.
Map<String, String> fieldErrorsFrom(List<FieldProblem> details) {
  final byField = <String, List<String>>{};
  for (final detail in details) {
    final messages = byField.putIfAbsent(detail.field, () => []);
    if (!messages.contains(detail.message)) messages.add(detail.message);
  }
  return {
    for (final MapEntry(key: field, value: messages) in byField.entries)
      field: messages.join('\n'),
  };
}
