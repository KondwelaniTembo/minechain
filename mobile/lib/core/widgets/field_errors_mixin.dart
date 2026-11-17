// One way, shared by every form, to keep the sentences shown under fields
// ("Enter your username.", or a server detail such as "That username is
// already taken.") and to clear a field's sentence as soon as the user
// changes that field.
//
// Why: an error that stays on screen while the user is fixing it reads as
// "still wrong", which is confusing. Clearing it on the first edit says "we
// will look again when you press the button", which is exactly what happens:
// the button runs every check again.
//
// Why a mixin: the four forms (login, password prompt, register, activate)
// each have their own State class. A mixin adds the same fields and methods
// to each of them without a shared base class. `on State<T>` means it can
// only be mixed into a State, so it may call setState.
//
// Why not Form + AutovalidateMode.onUserInteractionIfError: that re-runs a
// field's validator on each edit, but the server's errors (a taken username,
// a too-common password) cannot be re-checked on the phone, and a re-run
// would keep "The two passwords are not the same." on screen while the user
// is still typing. Clearing on change treats both kinds of error the same.
//
// How to use it in a form:
//   - show:  errorText: fieldError('username')
//   - clear: TextField(onChanged: (_) => clearFieldError('username'))
//   - set:   setState(() => setFieldErrors({...}))   on submit or failure

import 'package:flutter/widgets.dart';

mixin FieldErrorsMixin<T extends StatefulWidget> on State<T> {
  /// The sentence under each field, keyed by the field's name. For server
  /// errors the key is the API's own field name (`username`, `password`).
  Map<String, String> _fieldErrors = const {};

  /// The sentence to show under [field], or null for none.
  String? fieldError(String field) => _fieldErrors[field];

  bool hasFieldError(String field) => _fieldErrors.containsKey(field);

  /// Replaces every field's sentence at once (an empty map clears them all).
  /// Call it inside setState, like any other change the screen must show.
  void setFieldErrors(Map<String, String> errors) {
    _fieldErrors = Map.unmodifiable(errors);
  }

  /// Removes [field]'s sentence, if it has one. Meant for the field's
  /// onChanged, which only fires when the user edits it (not when the code
  /// calls controller.clear()), so clearing a password after an attempt
  /// does not wipe the reason it was refused.
  void clearFieldError(String field) {
    if (!_fieldErrors.containsKey(field)) return; // nothing to redraw
    setState(() {
      _fieldErrors = Map.unmodifiable({..._fieldErrors}..remove(field));
    });
  }
}
