// The custody record ID format: MC-<4 digits>-<3 capitals>-<4 digits>,
// checked exactly as scanned.

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/registration/domain/custody_record.dart';
import 'package:minechain/features/registration/domain/payload_format.dart';

void main() {
  group('accepted', () {
    for (final id in [
      'MC-2026-LSK-0001',
      'MC-2027-CHP-9999',
      'MC-0000-AAA-0000',
    ]) {
      test(id, () {
        expect(isCustodyRecordId(id), isTrue);
        // Never refused later by the payload builder (the server's grammar).
        expect(isQrCode(id), isTrue);
      });
    }
  });

  group('refused', () {
    for (final (name, scanned) in [
      ('a website link', 'https://myqrcode.mobi/8107b644'),
      ('a short link', 'http://scn.by/7d1k2'),
      ('lower case', 'mc-2026-lsk-0001'),
      ('mixed case', 'MC-2026-Lsk-0001'),
      ('a space before', ' MC-2026-LSK-0001'),
      ('a space after', 'MC-2026-LSK-0001 '),
      ('a line break after', 'MC-2026-LSK-0001\n'),
      ('a space inside', 'MC-2026- LSK-0001'),
      ('too long', 'MC-2026-LSK-00011'),
      ('a longer year', 'MC-20260-LSK-0001'),
      ('four letters', 'MC-2026-LUSK-0001'),
      ('too short', 'MC-2026-LSK-001'),
      ('the record inside a link', 'https://x.example/MC-2026-LSK-0001'),
      ('the old demo form', 'MC-DEMO-000001'),
      ('Arabic-Indic digits', 'MC-٢٠٢٦-LSK-0001'),
      ('empty', ''),
    ]) {
      test(name, () => expect(isCustodyRecordId(scanned), isFalse));
    }
  });
}
