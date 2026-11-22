// Counting a report's rows (reports plan, T1).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/reports/domain/csv_records.dart';

const bom = [0xEF, 0xBB, 0xBF];

List<int> file(String text) => [...bom, ...utf8.encode(text)];

void main() {
  test('api.md\'s transactions example: a header and one record', () {
    // The example's record, shortened; the shape is what matters.
    final bytes = file(
      '"step_id","consignment_id","qr_code","mineral"\r\n'
      '"7a3e9b10-0000-4000-8000-000000000001",'
      '"5c0d7e21-0000-4000-8000-000000000001","MC-2026-000001","gold"\r\n',
    );
    expect(countRecords(bytes), 1);
  });

  test('api.md\'s audit-trail example: JSON with "" inside a cell', () {
    final bytes = file(
      '"event_time_utc","event","alert_details"\r\n'
      '"2026-11-10T07:02:10.101Z","step_recorded",""\r\n'
      '"2026-11-10T07:02:10.104Z","alert_raised",'
      '"{""weightMg"": ""1200000"", ""thresholdPercent"": 10}"\r\n',
    );
    expect(countRecords(bytes), 2);
  });

  test('the header alone is no rows', () {
    expect(countRecords(file('"step_id","qr_code"\r\n')), 0);
  });

  test('an empty file, or a BOM alone, is no rows', () {
    expect(countRecords(const []), 0);
    expect(countRecords(bom), 0);
  });

  test('a line break inside an officer\'s notes is not a new record', () {
    final bytes = file(
      '"event","review_notes"\r\n'
      '"alert_reviewed","Weighed again at the depot.\r\nThe scale was off."\r\n'
      '"alert_dismissed","Fine"\r\n',
    );
    expect(countRecords(bytes), 2);
  });

  test('a last record without its CRLF is still counted', () {
    expect(countRecords(file('"a"\r\n"1"\r\n"2"')), 2);
  });

  test('letters outside ASCII do not confuse the count', () {
    expect(countRecords(file('"zone_name"\r\n"Kasempa – North ✓"\r\n')), 1);
  });

  group('withoutByteOrderMark (T5b)', () {
    Uint8List bytes(List<int> list) => Uint8List.fromList(list);

    test('the BOM goes, the rest is kept byte for byte', () {
      const text = '"step_id"\r\n"s1"\r\n';
      expect(withoutByteOrderMark(bytes(file(text))), utf8.encode(text));
    });

    test('a file without one comes back unchanged', () {
      final plain = bytes(utf8.encode('"step_id"\r\n'));
      expect(withoutByteOrderMark(plain), same(plain));
    });

    test('a BOM alone leaves nothing, and is still no rows', () {
      final left = withoutByteOrderMark(bytes(bom));
      expect(left, isEmpty);
      expect(countRecords(left), 0);
    });

    test('only a whole BOM at the very start is taken', () {
      expect(withoutByteOrderMark(bytes([0xEF, 0xBB])), [0xEF, 0xBB]);
      final later = bytes([0x22, ...bom, 0x22]);
      expect(withoutByteOrderMark(later), later);
    });

    test('the count is the same with or without it', () {
      const text = '"zone_name"\r\n"Kasempa – North ✓"\r\n"b"\r\n';
      expect(countRecords(withoutByteOrderMark(bytes(file(text)))), 2);
    });
  });
}
