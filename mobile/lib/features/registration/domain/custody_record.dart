// What a scanned QR code must look like to count as a MineChain custody
// record (decision Mobile, custody record IDs).
//
// The server's QR grammar ("4–128 characters from A–Z a–z 0–9 . _ : / -",
// payload_format.dart) is far wider: it lets through website links such as
// "https://myqrcode.mobi/8107b644". On the A57 the camera picked up such
// codes by itself, before the miner had aimed. So the scanner accepts only
// the custody record ID format, MC-<year>-<3 capital letters>-<4 digits>,
// for example MC-2026-LSK-0001. Every such ID also passes the server's
// grammar, so nothing accepted here is refused when the payload is built.
//
// The value is checked exactly as scanned: no trimming, no case change.

final RegExp _custodyRecordId = RegExp(r'^MC-[0-9]{4}-[A-Z]{3}-[0-9]{4}$');

/// Whether [scanned] is a custody record ID, such as `MC-2026-LSK-0001`.
bool isCustodyRecordId(String scanned) => _custodyRecordId.hasMatch(scanned);
