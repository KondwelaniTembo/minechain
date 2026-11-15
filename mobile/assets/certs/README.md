# Pinned root certificates

The app trusts **only** these three root certificates for its connection to the MineChain
API (`lib/core/network/pinned_http_client.dart`). The phone's own certificate store is never
used. Decision: `docs/decisions.md`, "Certificate pinning" (31 Oct, 1 Nov) and
"Deployment (11)"; plan: `docs/plans/mobile-foundation-plan.md` section 5.2.

Each file is PEM text holding one certificate. The SHA-256 fingerprints are of the
certificate's DER bytes (what `certutil` and crt.sh show), not of the PEM text.
`test/core/network/pinned_http_client_test.dart` checks them on every test run, so a swapped
or edited file is caught; `tool/check_tls.dart` prints them too.

## GTS Root R4

| | |
|---|---|
| File | `gts_root_r4.pem` |
| CA | Google Trust Services |
| Official source | https://pki.goog/repo/certs/gtsr4.pem |
| SHA-256 (verified with Windows `certutil`) | `349dfa4058c5e263123b398ae795573c4e1313c83fe68f93556cd5e8031b3c7d` |
| Matches the value published by | Google Trust Services and the Mozilla root store |
| Verified | 16 Nov 2026, 01:28 |

## GlobalSign ECC Root CA – R4

| | |
|---|---|
| File | `globalsign_ecc_root_r4.pem` |
| CA | GlobalSign; operated by Google Trust Services since 2016 |
| Official source | https://pki.goog/repo/certs/gsr4.pem |
| SHA-256 (verified with Windows `certutil`) | `b085d70b964f191a73e4af0d54ae7a0e07aafdaf9b71dd0862138ab7325a24a2` |
| Matches the value published by | Google Trust Services and the Mozilla root store |
| Verified | 16 Nov 2026, 01:28 |

## ISRG Root X1 (backup)

| | |
|---|---|
| File | `isrg_root_x1.pem` |
| CA | Internet Security Research Group (Let's Encrypt) |
| Official source | https://letsencrypt.org/certs/isrgrootx1.pem |
| SHA-256 (verified with Windows `certutil`) | `96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6` |
| Matches the value published by | crt.sh, certificate id 9314791 |
| Verified | 16 Nov 2026, 01:28 |

## Why roots, and why these three

- **Roots, not the server's own (leaf) certificate.** Render replaces its certificate
  automatically (the one in use on 14 Nov expires 21 Dec 2026). Pinning the leaf would lock
  every installed app out at the next renewal. A root lasts for many years (GTS Root R4 until
  2036, GlobalSign ECC Root CA – R4 until 2038) and survives renewals, while still refusing a
  certificate from any other CA, including a fake CA installed on the phone to intercept
  traffic.
- **Not the intermediate (WE1) either**: Render could move to another intermediate of the
  same CA at any renewal, with the same lock-out.
- **GTS Root R4 and GlobalSign ECC Root CA – R4 both**: the intermediate WE1 chains to either,
  and the phone, not the server, chooses which path to build. Pinning one would fail on
  phones that choose the other.
- **ISRG Root X1 as a backup from a second CA**: if Render moves its certificates to Let's
  Encrypt, the app keeps working.

## If Render moves to a CA that is not pinned

The app **fails closed**: every request is refused with a TLS handshake error, and the user
sees "The connection is not safe, so the app stopped." No data is sent anywhere. It stays
that way until an app update adds the new CA's root. This is the price of pinning: an
outage after a CA change is accepted in exchange for refusing an interception that a
compromised or user-installed CA would otherwise allow. Re-check the served chain whenever
the hosting changes (`docs/deployment.md`, re-check list).
