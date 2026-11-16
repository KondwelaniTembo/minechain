// The licence number's shape while it is typed: ZM-ABC-1234 (agreed for the
// prototype): two letters, a dash, three letters, a dash, four digits.
//
// A TextInputFormatter sits between the keyboard and the text field. Every
// time the text would change, Flutter hands it the old value and the new one,
// and shows whatever it returns instead. So the field can never hold
// "zm asm 0001" or "ZMASM00011": it holds "ZM-ASM-0001".
//
// THE SERVER IS THE AUTHORITY. Today the API accepts any licence of 1–50
// characters (api.md, POST /auth/register), and the firm rule for this shape
// will be added on the server later. This file only helps the person type it
// tidily; it decides nothing on the server's behalf, and a different app (or
// an old version of this one) would not be held to it.

import 'package:flutter/services.dart';

/// The agreed shape, for the register form's hint and its one local check.
abstract final class LicenceNumberFormat {
  static const String example = 'ZM-ASM-0001';

  /// 9 letters and digits plus 2 dashes.
  static const int maxLength = 11;

  static final RegExp _complete = RegExp(r'^[A-Z]{2}-[A-Z]{3}-[0-9]{4}$');

  /// Whether [text] is a whole licence number in the agreed shape.
  static bool isComplete(String text) => _complete.hasMatch(text);
}

/// Formats the licence number as it is typed or pasted.
///
/// - letters become capitals;
/// - letters are kept only in the five letter places, digits only in the four
///   digit places; anything else (spaces, dashes, punctuation, a digit where
///   a letter belongs) is dropped;
/// - the dashes are put in by the formatter, never typed;
/// - at most 9 letters and digits, so at most 11 characters;
/// - Backspace just after a dash deletes the character before the dash, as
///   people expect, instead of the dash coming straight back.
///
/// A dash is added once the next group has started ("ZM" -> "ZM-A"), not
/// as soon as a group is full ("ZM" -> "ZM-"). That keeps Backspace simple:
/// deleting the "A" of "ZM-A" leaves "ZM", with no stray dash to delete.
class LicenceNumberFormatter extends TextInputFormatter {
  const LicenceNumberFormatter();

  /// How many letters and digits a whole licence number has.
  static const int _places = 9;

  /// The first 5 places hold letters, the last 4 digits.
  static bool _isLetterPlace(int index) => index < 5;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var (chars, cursor) = _keep(newValue.text, _cursorOf(newValue));

    // Only a dash was deleted: the letters and digits are unchanged but the
    // text got shorter. Delete the neighbouring character instead, on the
    // side the cursor moved from, or nothing would seem to happen.
    final (oldChars, _) = _keep(oldValue.text, _cursorOf(oldValue));
    if (newValue.text.length < oldValue.text.length && chars == oldChars) {
      final backspace = _cursorOf(newValue) < _cursorOf(oldValue);
      final remove = backspace ? cursor - 1 : cursor;
      if (remove >= 0 && remove < chars.length) {
        // Re-run _keep on the rest: removing one character moves the later
        // ones into different places, and they must still fit their places.
        (chars, cursor) = _keep(
          chars.substring(0, remove) + chars.substring(remove + 1),
          remove,
        );
      }
    }

    final text = _withDashes(chars);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: _offsetAfter(cursor).clamp(0, text.length),
      ),
    );
  }

  /// Where the cursor is in [value] (the end of a selection), or the end of
  /// the text if the field has no cursor.
  static int _cursorOf(TextEditingValue value) {
    final end = value.selection.end;
    return (end < 0 || end > value.text.length) ? value.text.length : end;
  }

  /// The letters and digits of [raw] that fit their places, in capitals, and
  /// how many of them come before [rawCursor] (where the cursor ends up).
  static (String, int) _keep(String raw, int rawCursor) {
    final kept = StringBuffer();
    var cursor = 0;
    for (var i = 0; i < raw.length && kept.length < _places; i++) {
      final ch = raw[i].toUpperCase();
      // One character, plain A–Z or 0–9 only: "é" or "ß" ("SS" in capitals)
      // are not licence characters.
      if (ch.length != 1) continue;
      final code = ch.codeUnitAt(0);
      final isLetter = code >= 0x41 && code <= 0x5A; // A–Z
      final isDigit = code >= 0x30 && code <= 0x39; // 0–9
      final fits = _isLetterPlace(kept.length) ? isLetter : isDigit;
      if (!fits) continue;
      kept.write(ch);
      if (i < rawCursor) cursor++;
    }
    return (kept.toString(), cursor);
  }

  /// "ZMASM0001" -> "ZM-ASM-0001"; "ZMA" -> "ZM-A"; "ZM" -> "ZM".
  static String _withDashes(String chars) {
    final out = StringBuffer();
    for (var i = 0; i < chars.length; i++) {
      if (i == 2 || i == 5) out.write('-');
      out.write(chars[i]);
    }
    return out.toString();
  }

  /// The position in the dashed text just after [count] letters and digits.
  static int _offsetAfter(int count) =>
      count + (count > 2 ? 1 : 0) + (count > 5 ? 1 : 0);
}
