// How many rows a downloaded report has (reports plan, T1), for the line
// "142 rows" under the file. Plain Dart.
//
// The server writes RFC 4180 CSV (api.md, "The file"): every field in double
// quotes, a `"` inside written `""`, every record ending with CRLF. A line
// break can sit inside a field (an officer's notes), so counting lines would
// be wrong. Instead the count is of line feeds outside quotes. A `""` flips
// "inside quotes" twice, so it changes nothing, which is exactly right.
//
// Works on the bytes: `"`, CR and LF are single bytes in UTF-8 and never
// part of a longer character, and the BOM at the start is not one of them.

import 'dart:typed_data';

const int _quote = 0x22;
const int _lineFeed = 0x0A;

/// The number of data records in [bytes], the header row not counted. A
/// file with the header alone, or nothing, has 0.
int countRecords(List<int> bytes) {
  var records = 0;
  var inQuotes = false;
  var sinceLastRecord = false;
  for (final byte in bytes) {
    if (byte == _quote) {
      inQuotes = !inQuotes;
      sinceLastRecord = true;
    } else if (byte == _lineFeed && !inQuotes) {
      records++;
      sinceLastRecord = false;
    } else {
      sinceLastRecord = true;
    }
  }
  // The server ends the last record with CRLF too; a file that does not is
  // still counted fully. A BOM alone is not a record.
  if (sinceLastRecord && !_onlyBom(bytes)) records++;
  return records > 0 ? records - 1 : 0;
}

bool _onlyBom(List<int> bytes) =>
    bytes.length == 3 &&
    bytes[0] == 0xEF &&
    bytes[1] == 0xBB &&
    bytes[2] == 0xBF;

/// [bytes] without the UTF-8 byte order mark the server puts first (reports
/// T5b): Google Sheets on Android reads the file as Western (Windows-1252),
/// so the mark showed as "ï»¿" before the first header and its quotes showed
/// too. The rest is kept byte for byte. A file without the mark comes back
/// unchanged.
Uint8List withoutByteOrderMark(Uint8List bytes) =>
    bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF
    ? Uint8List.sublistView(bytes, 3)
    : bytes;
