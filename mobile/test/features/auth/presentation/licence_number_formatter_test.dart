// The licence number formatter on its own: plain values in, plain values out.
// A formatter is a pure function of (old value, new value), so each keystroke
// or paste is one call.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/presentation/licence_number_formatter.dart';

const formatter = LicenceNumberFormatter();

/// A field's value with the cursor at [cursor] (the end if left out).
TextEditingValue value(String text, [int? cursor]) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: cursor ?? text.length),
);

int cursorOf(TextEditingValue v) => v.selection.baseOffset;

/// Types [keys] one at a time at the cursor, as a keyboard would.
TextEditingValue type(String keys, {TextEditingValue? from}) {
  var current = from ?? value('');
  for (final key in keys.split('')) {
    final at = cursorOf(current);
    final text =
        current.text.substring(0, at) + key + current.text.substring(at);
    current = formatter.formatEditUpdate(current, value(text, at + 1));
  }
  return current;
}

/// Pastes [pasted] into an empty field.
TextEditingValue paste(String pasted) =>
    formatter.formatEditUpdate(value(''), value(pasted));

/// One Backspace at the cursor of [before].
TextEditingValue backspace(TextEditingValue before) {
  final at = cursorOf(before);
  final text = before.text.substring(0, at - 1) + before.text.substring(at);
  return formatter.formatEditUpdate(before, value(text, at - 1));
}

void main() {
  group('typing', () {
    test('a whole number, lowercase, becomes ZM-ASM-0001', () {
      final result = type('zmasm0001');
      expect(result.text, 'ZM-ASM-0001');
      expect(cursorOf(result), 11);
    });

    test('a dash appears once the next group starts', () {
      expect(type('zm').text, 'ZM');
      final three = type('zma');
      expect(three.text, 'ZM-A');
      expect(cursorOf(three), 4); // after the A, past the dash
      expect(type('zmasm').text, 'ZM-ASM');
      expect(type('zmasm0').text, 'ZM-ASM-0');
    });

    test('typed dashes are ignored: the formatter puts them in', () {
      expect(type('zm-asm-0001').text, 'ZM-ASM-0001');
    });
  });

  group('pasting', () {
    test('lowercase', () {
      expect(paste('zm-asm-0001').text, 'ZM-ASM-0001');
    });

    test('with spaces, and spaces around it', () {
      expect(paste(' zm asm 0001 ').text, 'ZM-ASM-0001');
      expect(paste('ZM ASM 0001').text, 'ZM-ASM-0001');
    });

    test('the cursor ends after the pasted number', () {
      expect(cursorOf(paste('zm asm 0001')), 11);
    });
  });

  group('the right kind in each place', () {
    test('digits in the letter places are dropped', () {
      expect(type('1').text, '');
      expect(paste('Z1M').text, 'ZM');
      expect(paste('ZM-A5SM-0001').text, 'ZM-ASM-0001');
    });

    test('letters in the digit places are dropped', () {
      expect(paste('ZM-ASM-A001').text, 'ZM-ASM-001');
      expect(type('x', from: paste('ZM-ASM')).text, 'ZM-ASM');
    });

    test('punctuation and letters outside A-Z are dropped', () {
      expect(paste('ZM.É-ASM/0001!').text, 'ZM-ASM-0001');
      // "ß" becomes "SS" in capitals: two characters, so not a licence letter.
      expect(paste('ßZM').text, 'ZM');
    });
  });

  group('too long', () {
    test('a longer paste is cut to 11 characters', () {
      expect(paste('ZM-ASM-000123').text, 'ZM-ASM-0001');
    });

    test('typing on a full number changes nothing', () {
      final full = paste('ZM-ASM-0001');
      expect(type('9', from: full).text, 'ZM-ASM-0001');
    });
  });

  group('deleting over dashes', () {
    test('Backspace after a group start also removes the dash', () {
      final result = backspace(value('ZM-A'));
      expect(result.text, 'ZM');
      expect(cursorOf(result), 2);
    });

    test('Backspace on a dash deletes the letter before it', () {
      // Cursor just after the first dash of ZM-ASM.
      final result = backspace(value('ZM-ASM', 3));
      expect(result.text, 'ZA-SM');
      expect(cursorOf(result), 1);
    });

    test('Backspace from the end, step by step, back to nothing', () {
      var current = value('ZM-ASM-0');
      final seen = <String>[];
      while (current.text.isNotEmpty) {
        current = backspace(current);
        seen.add(current.text);
      }
      expect(seen, ['ZM-ASM', 'ZM-AS', 'ZM-A', 'ZM', 'Z', '']);
    });

    test('deleting everything at once', () {
      final result = formatter.formatEditUpdate(
        value('ZM-ASM-0001'),
        value(''),
      );
      expect(result.text, '');
    });
  });

  group('LicenceNumberFormat', () {
    test('isComplete: only the whole agreed shape', () {
      expect(LicenceNumberFormat.isComplete('ZM-ASM-0001'), isTrue);
      expect(LicenceNumberFormat.isComplete('ZM-ASM-001'), isFalse);
      expect(LicenceNumberFormat.isComplete('ZM-ASM'), isFalse);
      expect(LicenceNumberFormat.isComplete('zm-asm-0001'), isFalse);
      expect(LicenceNumberFormat.isComplete(''), isFalse);
    });

    test('the screen\'s sentences use the same example', () {
      expect(AppText.licenceNumberHint, contains(LicenceNumberFormat.example));
      expect(AppText.licenceIncomplete, contains(LicenceNumberFormat.example));
      expect(
        LicenceNumberFormat.example.length,
        LicenceNumberFormat.maxLength,
      );
    });
  });
}
