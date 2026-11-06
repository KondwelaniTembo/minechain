# MineChain signing specification

How the Android app signs each custody step, and how the backend verifies it and builds the
hash it anchors on Sepolia. The app (Dart) and the backend (JavaScript) must follow it
byte for byte: one differing byte and a genuine signature stops verifying.

Every id, code and value in this document is fake. Ids follow the pattern
`3f2b6c1e-0000-4000-8000-000000000001`, which no real record will ever have.

**Status:** version 1 of the payload format and version 1 of the anchor hash. The test
vectors (section 9) are produced in a later step.

---

## 1. Purpose and scope

Every custody step is signed on the phone by the person who performs it:

| Step | Signed by | Payload type |
|---|---|---|
| Registration at extraction (FR-01) | the miner | `registration` |
| Handoff to a transporter | the transporter taking custody | `handoff` |
| Purchase | the licensed buyer | `purchase` |

The phone signs with a P-256 key held in the Android Keystore (FR-02). The key never leaves
the device (NFR-02). The backend holds only the public key. For each step it:

1. checks that the payload is in the exact format below;
2. checks that the signer named in the payload is the logged-in user;
3. verifies the signature against that user's registered public key;
4. stores the payload, signature and key as evidence;
5. builds the anchor hash (section 7) that is later written on-chain (FR-03).

Steps can be signed offline and sent up to 72 hours later (NFR-04). Nothing in the format
depends on the network being available when the step is signed.

**The custody document.** Each consignment travels with a numbered paper **Consignment
Custody Record** carrying a pre-printed, unique QR code. The record goes with the minerals,
not on the bag, and it is scanned at every step. Its QR code is the `qr_code` field, the
one reference to the consignment that every party has, even offline. In this project it is
a clearly labelled **demonstration document, not an official government form**. MineChain
produces chain-of-custody evidence that supports official certification (for example the
ICGLR Regional Certificate for gold, and the national export permit). It does not replace
them.

---

## 2. Keys

- **Algorithm:** ECDSA on P-256 (also called secp256r1 or prime256v1), with SHA-256.
- **Public key format:** SubjectPublicKeyInfo (SPKI), DER-encoded, uncompressed point. This
  is always **exactly 91 bytes**. It is what Android's `PublicKey.getEncoded()` returns for
  a Keystore EC key.
- **On the wire:** standard base64 (RFC 4648 section 4, with `=` padding, no line breaks).
- **The server refuses** a key that:
  - is not exactly 91 bytes;
  - does not parse as SPKI DER, or is PEM text instead of DER;
  - is not an EC key on P-256 (for example secp256k1, Ed25519 or RSA);
  - uses a compressed point or explicit curve parameters;
  - has a point that is not on the curve;
  - does not re-encode to exactly the same bytes.

**Registering a key (built in a later step).** After the first login on a device, the app
creates a key pair in the Keystore and sends the public key to the server. A key can be
registered **only while the account has none**. A user cannot replace their own key: if they
could, a stolen password alone would let an attacker install their own key and sign records
as the victim.

**Lost device, new phone or reinstalled app:**

1. The user tells an administrator.
2. The administrator **suspends** the account. Any token on the lost phone stops working
   at once.
3. The administrator **resets the device key** (sets it to none, audited as
   `user.key_reset`; built in a later step).
4. The administrator **reactivates** the account.
5. The user logs in on the new device, which registers a new key.

Steps already stored keep verifying, because each one keeps a copy of the key that signed
it. Records signed by the old phone that arrive after the reset no longer verify, which is
the purpose of the reset. Records that were never synced from a lost phone are lost with it
(section 10).

---

## 3. Payload format, version 1

### Byte rules

- The payload is **printable ASCII only** (bytes 0x21 to 0x7E), plus LF (0x0A) at the end
  of each line. No other byte may appear: no spaces, tabs, CR, BOM or any byte of 0x80 or
  above.
- Because it is pure ASCII, it is also valid UTF-8, and Unicode normalisation never applies.
  No field holds free text. A future field with free text would need a new version that
  defines its normalisation (NFC).
- Every line is `key=value` and **ends with LF, including the last line**. There are no
  empty lines.
- **Line 1 is the header**: `minechain-step/1/<type>`, where `<type>` is `registration`,
  `handoff` or `purchase`. The `1` is the format version.
- The remaining lines follow the **fixed order** for that type, below. A missing, extra,
  repeated or reordered line makes the payload invalid.

Because the type is part of the signed bytes, a signature for one kind of step can never be
presented as another.

### Fields, in order

| Line | `registration` | `handoff` | `purchase` |
|---|---|---|---|
| 1 | `minechain-step/1/registration` | `minechain-step/1/handoff` | `minechain-step/1/purchase` |
| 2 | `step_id` | `step_id` | `step_id` |
| 3 | `actor_id` | `actor_id` | `actor_id` |
| 4 | `qr_code` | `qr_code` | `qr_code` |
| 5 | `mineral` | — | — |
| 6 | `weight_mg` | `weight_mg` | `weight_mg` |
| 7 | `latitude` | `latitude` | `latitude` |
| 8 | `longitude` | `longitude` | `longitude` |
| 9 | `captured_at` | `captured_at` | `captured_at` |

A handoff or purchase payload therefore has 8 lines and a registration 9.

### Value grammar

| Field | Rule | Example |
|---|---|---|
| `step_id` | A UUID made by the phone when it signs the step, in **lower-case** hex, `8-4-4-4-12`. Upper case is refused, not folded. Stored as the step's idempotency key | `6f1d2c3a-0000-4000-8000-000000000001` |
| `actor_id` | The signer's user id as the server issued it, lower-case UUID. Must equal the logged-in user | `3f2b6c1e-0000-4000-8000-000000000001` |
| `qr_code` | The custody record's code: 4–128 characters from `A–Z a–z 0–9 . _ : / -` | `MC-2026-000123` |
| `mineral` | `gold`, `copper`, `cobalt`, `manganese`, `emerald` or `amethyst` | `gold` |
| `weight_mg` | Whole milligrams as decimal digits: no sign, no leading zeros, at least `1`, at most `9223372036854775807` | `1500000` (1.5 kg) |
| `latitude` | Decimal degrees with **exactly 6 decimal places**, from `-90.000000` to `90.000000`. Pattern `-?(0\|[1-9][0-9]{0,2})\.[0-9]{6}`. `-0.000000` is refused; zero is written `0.000000` | `-15.419751` |
| `longitude` | The same, from `-180.000000` to `180.000000` | `28.287496` |
| `captured_at` | The phone's time when the step was captured, in UTC, as `YYYY-MM-DDTHH:MM:SS.sssZ`: exactly 3 fraction digits and a literal `Z`, and a real calendar date and time | `2026-11-10T08:00:00.000Z` |

The fixed width of the numbers is deliberate: Dart's `double.toString()` and JavaScript's
`String(number)` print some values differently, so neither is ever used. The server never
turns `latitude`, `longitude` or `weight_mg` into a floating-point number. The text goes to
PostgreSQL as an exact `numeric(9,6)` or `bigint`.

### Example

A registration (fake values). `⏎` marks each LF and is not part of the bytes:

```
minechain-step/1/registration⏎
step_id=6f1d2c3a-0000-4000-8000-000000000001⏎
actor_id=3f2b6c1e-0000-4000-8000-000000000001⏎
qr_code=MC-2026-000123⏎
mineral=gold⏎
weight_mg=1500000⏎
latitude=-15.419751⏎
longitude=28.287496⏎
captured_at=2026-11-10T08:00:00.000Z⏎
```

A handoff of the same consignment, signed by a transporter:

```
minechain-step/1/handoff⏎
step_id=6f1d2c3a-0000-4000-8000-000000000002⏎
actor_id=3f2b6c1e-0000-4000-8000-000000000002⏎
qr_code=MC-2026-000123⏎
weight_mg=1495000⏎
latitude=-15.390012⏎
longitude=28.322540⏎
captured_at=2026-11-10T14:30:05.250Z⏎
```

### Only one valid spelling

The server verifies the signature over the bytes it received, then parses them and
requires that writing the parsed fields back out gives **exactly the same bytes**. So there
is only one valid way to write any step, and every value the server stores comes from what
was signed.

---

## 4. Producing the values in Dart

The phone must build the payload **once, when the step is captured**, store that exact
string in the encrypted local database, sign it, and later send the same string. It must
never rebuild the payload from stored fields before sending.

### Coordinates

Round to whole millionths of a degree, then format the integer by hand.
`toStringAsFixed(6)` must not be used: it prints `-0.000000` for negative zero.

```dart
/// Formats a latitude or longitude for the signed payload (version 1).
String formatCoordinate(double value) {
  // Whole millionths of a degree. Dart's round() rounds halves away from zero.
  final micro = (value * 1000000).round();
  if (micro == 0) return '0.000000';
  final sign = micro < 0 ? '-' : '';
  final abs = micro.abs();
  final whole = abs ~/ 1000000;
  final fraction = (abs % 1000000).toString().padLeft(6, '0');
  return '$sign$whole.$fraction';
}
```

Examples: `-15.4197512` → `-15.419751`; `28.288` → `28.288000`; `28.2874968` → `28.287497`;
`-0.0000004` → `0.000000` (never `-0.000000`).

A value exactly halfway between two millionths is rare from GPS, and in floating point it
is often stored slightly below or above the half (`0.0000005 * 1000000` is
`0.49999999999999994`), so it can round either way. That does not matter: the phone signs
whatever text this function returns, and the server checks that text, never the original
`double`.

After rounding, the app must check the range (±90 for latitude, ±180 for longitude). The
server refuses anything outside it.

Only the phone ever converts a GPS reading to this text, so the rounding rule only has to
be applied once, on the phone. Any JavaScript tool that does the same must round halves away
from zero too: `Math.sign(x) * Math.round(Math.abs(x) * 1e6)`. Plain `Math.round` rounds
`-2.5` to `-2`, where Dart gives `-3`.

### Capture time

**Truncate** to whole milliseconds (drop the microseconds, never round), convert to UTC, and
format by hand. `toIso8601String()` must not be used: in UTC it adds 3 more digits whenever
the microseconds are not zero (`2026-11-10T08:00:00.123456Z`).

```dart
/// Formats the capture time for the signed payload (version 1).
String formatCapturedAt(DateTime time) {
  final utc = time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final year = utc.year.toString().padLeft(4, '0');
  // utc.millisecond ignores utc.microsecond, so this truncates, never rounds.
  final millis = utc.millisecond.toString().padLeft(3, '0');
  return '$year-${two(utc.month)}-${two(utc.day)}'
      'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}.${millis}Z';
}
```

Example: a local time with 123 ms and 456 µs gives `….123Z`, never `….124Z`.

This string matches JavaScript's `Date.prototype.toISOString()` for years 0000 to 9999.

### Other values

- **Ids:** `step_id` is a fresh random UUID (version 4) for each step, in lower case.
  `actor_id` is the user id exactly as the server returned it at login (always lower case).
- **Weight:** an `int` of milligrams, written with `toString()`. It must be at least 1.
- **QR code and mineral:** exactly as scanned or chosen, never trimmed or case-changed. The
  app refuses a scanned code that breaks the grammar.
- **Bytes to sign:** `utf8.encode(payload)`. The payload is ASCII, so this is one byte per
  character.

---

## 5. Signing and verifying

- **The phone** signs the payload bytes with `Signature.getInstance("SHA256withECDSA")` and
  the Keystore private key. The algorithm hashes the bytes with SHA-256 itself, so the app
  **must not hash the payload first**.
- **Signature format: DER only**, as `SHA256withECDSA` produces: an ASN.1
  `SEQUENCE { INTEGER r, INTEGER s }`, usually 70–72 bytes and never more than 72. The raw
  64-byte `r || s` form (IEEE P1363) is refused, and so is any DER that does not re-encode
  to exactly the same bytes.
- **On the wire:** standard base64 with padding, the same as keys. The server decodes it
  strictly: re-encoding the decoded bytes must give back the exact text. So base64url,
  missing padding and whitespace are all refused.
- **The server** verifies with Node's built-in `crypto.verify('sha256', payloadBytes, key,
  signature)` (DER encoding), against the logged-in user's registered public key. No
  extra packages are used.

**Transport (built in a later step).** Each step is sent as JSON, roughly
`{ "payload": "<the exact string>", "signature": "<base64>" }`. JSON writes each LF as `\n`,
and decoding gives back the exact string. The payload grammar has no `"` or `\`, so nothing
else is ever escaped.

**Malleability.** From any valid signature `(r, s)`, anyone can compute a second valid one,
`(r, n − s)`, for the **same** payload, without the private key. Nobody can change the
payload or sign a new one this way. MineChain does **not** require the "low-S" form, because
the Android Keystore does not produce it consistently, and requiring it would refuse about
half of all genuine signatures. Instead, **a signature is never used as an identifier**.
Steps are told apart by `step_id`, and retries are recognised by `step_id` plus the anchor
hash (section 6).

---

## 6. Replay and retries

A signed step may legitimately arrive up to 72 hours after it was signed. A time window
would therefore have to accept records at least 72 hours old, and a copied record replayed
within that window would pass. **Time cannot be the replay defence.**

Uniqueness is:

- `step_id` is inside the signed bytes, so it cannot be changed without breaking the
  signature.
- The server stores it as the step's idempotency key, and the database allows each user
  each key only once.
- **An exact copy** of a stored step (same payload, same signature) is a genuine retry. The
  server answers with the stored step and creates nothing.
- **The same `step_id` with anything different** (another payload, or the other
  malleability form of the signature) gives a different anchor hash, and the server
  refuses it with 409.
- `actor_id` is also signed and must equal the logged-in user, so a step can never be
  submitted under another account.

`captured_at` is the phone's clock, which the user controls. For now, a time in the future
or older than 72 hours is accepted and stored as signed (section 10). The server also stores
its own receipt time for every step (`transactions.received_at`, set by the database), so
both times are always available to the anomaly rules and reports.

---

## 7. Anchor hash, version 1

The hash anchored on-chain as `dataHash` and stored as `transactions.data_hash` (with
`hash_version = 1`):

```
data_hash = SHA-256(
     "minechain-anchor/1\n"                          (19 ASCII bytes)
  || uint32_be(len(payload))   || payload bytes
  || uint32_be(len(publicKey)) || signer public key  (SPKI DER, 91 bytes)
  || uint32_be(len(signature)) || signature          (DER, as received)
)
```

`uint32_be(n)` is `n` as 4 bytes, most significant first.

- **It reuses the signed bytes but is a separate hash.** The phone never signs or sees it;
  it belongs to the backend (contract specification, section 7).
- **The key and signature are included** so the chain also pins *who* signed. With the
  payload alone, someone with database access could swap in their own key and their own
  signature over the same payload, and the anchored hash would still match.
- **Length prefixes** make the boundaries unambiguous, so two different combinations of
  payload, key and signature can never produce the same bytes to hash.
- Because the signature is included, the two malleability forms of one signature give two
  different hashes. That is intended (section 6).
- The contract accepts any `bytes32` and never sees the payload, the key or any personal
  or location data.

---

## 8. Versioning rules

- **Any change** to the bytes of a payload (a field, the order, a grammar rule) needs a new
  format version in the header (`minechain-step/2/...`). Any change to how the anchor hash
  is built needs a new `hash_version` and a new prefix (`minechain-anchor/2`).
- **Old versions stay verifiable for ever.** Rows already stored and anchored keep their
  version. The server keeps the code to read and hash every version it has ever accepted.
- The server may stop **accepting new** steps in an old version, but only after the app
  version that produces them is retired. Steps still waiting offline must not be lost.

---

## 9. Test vectors

The vectors are kept in [`signing-vectors.json`](signing-vectors.json), read by the backend
tests and the Flutter tests alike. They are produced once by a script the developer runs
(`backend/scripts/make-signing-vectors.js`, in a later step), and then never changed.

Each vector holds:

- the typed fields of one step (one each for registration, handoff and purchase);
- the expected payload text, its bytes in hex, and their SHA-256;
- one public key (SPKI DER, base64) and one fixed DER signature over each payload;
- the expected anchor hash for each.

There are also **negative vectors**: payloads and signatures that must be refused, each
with the reason.

**No private key is ever stored.** The script creates a throwaway key pair, writes out only
the public key and the signatures, and discards the private key. A test can still check a
fixed signature with the public key. ECDSA signatures include a random value, so a new
signature over the same payload is different every time. Tests therefore compare payload
bytes and hashes exactly, and check signatures by verifying them.

How each side uses them:

- **Backend:** for every vector, build the payload from the fields and compare bytes; parse
  the payload back; verify the fixed signature; compare the anchor hash; refuse every
  negative vector.
- **Flutter:** for every vector, build the payload with `formatCoordinate`,
  `formatCapturedAt` and the field order, and compare bytes; verify the fixed signature with
  the public key.
- **Across both:** a payload signed by the real Keystore on the test device must verify on
  the server.

---

## 10. Known limits

- **A custody record could be moved to another consignment.** The QR code identifies the
  paper document, not the minerals themselves, so someone could swap a record onto
  different material. The weight is signed at every step, and the backend's 10% quantity
  check compares each step with the one before, so a swap to a noticeably different lot
  raises an alert. A swap between lots of almost the same weight would not.
- **The phone's clock is trusted for `captured_at`.** Times in the future or more than 72
  hours old are accepted and stored as signed. To be revisited with the anomaly rules.
- **No low-S rule.** Each valid signature has a second valid form. Handled by never using
  signatures as identifiers (section 5).
- **No key attestation.** The server does not check that a key really lives in hardware.
  Android key attestation is future work.
- **Unsynced records are lost with a lost phone.** Steps signed but never sent cannot be
  recovered once the device is gone.
- **No contract-level verification.** The contract trusts the backend's recorders. P-256
  verification on-chain is future work (contract specification, section 9).
