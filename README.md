# MineChain

A blockchain-anchored mobile application for secure mining supply chain verification in
Zambia, aimed at artisanal and small-scale miners.

Final-year project, BSc Computer Science, ZCAS University (2026).

> **Status: prototype complete (v1.0.0, November 2026).** Shown in a simulated supply chain
> on the public Ethereum Sepolia test network. It is not a production system.

## What it does

A bag of mineral (a *consignment*) carries a QR code. Every change of hands is recorded on
an Android phone and signed with a key that never leaves the phone. The signed record is
checked by a server, then fixed on the blockchain, so a later change to it can be detected.

| Step | Who | In the app |
|---|---|---|
| Registration at extraction | Miner | Scan the QR code, GPS fix, mineral, weight, Save (works offline) |
| Handoff | Transporter | Scan, see the server's check, weigh it yourself, Save |
| Purchase | Licensed buyer | Scan, check the chain, record the purchase |
| Supervision | Regulatory officer | Alerts (confirm a problem or clear it), check any consignment, dashboard, CSV reports and audit trails |
| Administration | System administrator | Account requests, accounts, licensed GPS zones, reports, blockchain anchoring status |

**On the server:**
- Every signature is verified.
- Five anomaly checks run on each step: duplicate consignment, quantity off by more than
  10%, outside every licensed GPS zone, bad signature, and wrong handoff order.
- A failed check raises an alert and holds the consignment until an officer decides.
- Accepted steps are anchored on Sepolia in custody order.

**On a scan,** the server recomputes each step's hash and compares it with the on-chain
event: it *matches*, *does not match*, is *not on the blockchain yet*, or the server *could
not reach the blockchain*.

## Architecture

| Layer | Technology | Folder |
|---|---|---|
| Mobile application | Flutter (Android 8.0+), Riverpod, go_router, P-256 key in the Android Keystore, encrypted local database (SQLite3MultipleCiphers, SQLCipher scheme, AES-256) | `mobile/` |
| API communication | HTTPS with TLS 1.3 only and pinned root certificates, JWT on every request | `mobile/lib/core/network/`, `backend/src/middleware/` |
| Backend processing | Node.js 22, Express 5, PostgreSQL, Zod, Argon2id, ethers 6; hosted on Render | `backend/` |
| Blockchain ledger | Solidity contract with OpenZeppelin AccessControl, Hardhat 3, Ethereum Sepolia | `contracts/` |

**Two rules shape the design:**
- **The phone never talks to the blockchain.** Only an authorised backend wallet writes.
- **The chain holds no personal data,** only IDs, hashes, the stage and the weight.

**Deployed contract (Sepolia):** `0x6419cB5268706E2aA4713AB3bCFc336248Ed158a`.

The whole codebase, folder by folder, with a debugging guide: **[docs/codebase.md](docs/codebase.md)**.

## Repository structure

| Folder | Contents |
|---|---|
| `mobile/` | Flutter Android app for the five roles |
| `backend/` | REST API, anchoring worker, migrations, seed and helper scripts |
| `contracts/` | `MineChain.sol`, its tests and the Sepolia deployment record |
| `docs/` | API, database, contract and signing specs; decisions log; plans; test log; security review; deployment record |

## Getting started

### Mobile app

You need Flutter 3.47.9 (stable) and an Android phone or emulator on Android 8.0 (API 26)
or later. The phone needs a screen lock, because the signing key requires one. Work from
`mobile/`, in PowerShell:

1. Create the settings file and put the API's `https://` address in it:
   ```powershell
   Copy-Item env/api.example.json env/api.json
   ```
   `env/api.json` is git-ignored. Never commit it.
2. Install the packages and run the debug build:
   ```powershell
   flutter pub get
   flutter run --dart-define-from-file=env/api.json
   ```
3. Build and install the release build:
   ```powershell
   flutter build apk --release --obfuscate --split-debug-info=build/symbols --dart-define-from-file=env/api.json
   adb install -r build\app\outputs\flutter-apk\app-release.apk
   ```
   Always use `adb install -r` to install over the app. Never uninstall it, and never use
   `flutter install`: either one erases the signing key and the unsent work.
4. Run the tests (no test makes a network connection):
   ```powershell
   flutter test
   ```

Without `--dart-define-from-file`, the app shows "built without its server address"
instead of starting.

The release build blocks screenshots and blanks the app in recent apps (`FLAG_SECURE`).
Use the debug build for screenshots.

### Backend

You need Node.js 22 and PostgreSQL. See [backend/README.md](backend/README.md) for the full
setup and the environment variables. From `backend/`:

```powershell
npm install
Copy-Item .env.example .env     # fill in local values; never commit .env
npm run migrate
npm run seed
npm run dev
```

### Contract

From `contracts/`:

```powershell
npm install
npx hardhat test
```

## Testing

| Suite | Command | Tests (23 Nov 2026) |
|---|---|---|
| Flutter unit and widget | `flutter test` (in `mobile/`) | 2623 |
| Backend unit and route | `npm test` (in `backend/`) | 2348 |
| Backend against real PostgreSQL | `npm run test:db` (in `backend/`) | 932 |
| Smart contract | `npx hardhat test` (in `contracts/`) | 37 |

All pass. Every feature was also checked on a Samsung Galaxy A57 and an Android 8.0
emulator against production. A full end-to-end run with all five roles passed on 23 Nov
2026 (`docs/plans/end-to-end-plan.md`). Every run is logged in `docs/testing-log.md`.

**Security.** An OWASP MASVS v2 review of the app found one High finding, which was fixed:
the signing key now needs a screen lock. The final review on 23 Nov 2026 found no Critical
or High findings (`docs/security-review.md`).

**Speed (NFR-03).** On the devices used, every local save took about 0.1 s (the
requirement is 3 s) and sends took 0.5–1.9 s on Wi-Fi or 4G (the requirement is 10 s on
3G). These were measured in debug builds, which are slower than release builds. A 3G
network and a 2 GB RAM phone were not tried.

## Scope

Built: FR-01 to FR-14, with recorded changes. The main changes:
- in-app alerts instead of push notifications;
- soft delete of accounts;
- GPS zone "edit" means rename;
- the chain ends at the purchase (no export stage).

Not built (future work):
- FR-15, multi-language interface;
- FR-16, signed PDF provenance certificate;
- push notifications.

Every decision, its alternatives and the known limitations are in
[docs/decisions.md](docs/decisions.md).

## Credits

The app's copper theme was designed by Mapalo Maseko (decision Mobile (35)).

## Licence

[MIT](LICENSE)
