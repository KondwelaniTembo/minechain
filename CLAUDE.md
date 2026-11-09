# CLAUDE.md

Guidance for Claude Code in this repository. This file is public, so keep it free of
secrets, personal details and text copied from private documents.

## Project summary

MineChain is a final-year BSc Computer Science project: a blockchain-anchored supply chain
verification app for mining in Zambia, aimed at artisanal and small-scale miners. It is a
prototype shown in a simulated supply chain, not a production system.

- **Stack:** Flutter Android app, Node.js REST API, Solidity contract on Ethereum Sepolia.
- **Roles:** miner, transporter, buyer, regulatory officer, system administrator.
- **Core flow:** a consignment is registered at extraction, handed off to a transporter and
  purchased by a licensed buyer. Each step is signed and anchored on-chain.
- **Deadline:** Sunday 15 November 2026.

### Four-layer architecture

| Layer | Lives in | Responsibility |
|---|---|---|
| Mobile Application | `mobile/` | Role-based UI, QR scanning, GPS capture, ECDSA key management, encrypted local database, offline sync |
| API Communication | `backend/` | REST API over TLS 1.3 with certificate pinning, JWT on every request |
| Backend Processing | `backend/` | Transaction processing, anomaly detection, reports, accounts, push notifications, PostgreSQL |
| Blockchain Ledger | `contracts/` | `registerConsignment`, `recordHandoff`, `recordPurchase`, each emitting an event |

Rules that shape the design:

- Only authorised backend wallets can write to the contract. Mobile never talks to the
  chain directly.
- Anomaly detection runs in the backend, not the contract. It has five checks: duplicate
  consignment ID, quantity discrepancy over 10%, GPS zone, ECDSA signature, and handoff order.
- A failed check creates an alert, notifies officers and holds the consignment.
- The app is offline-first: work is signed and cached locally, then synced when the network
  returns.

## Current status

Updated 9 Nov 2026. Read this first in a new session, then `docs/decisions.md`.

- **Branch:** `feature/backend-logic`, last code commit `f149839` (the gas-sizing fix after
  8.8); the 8.9 docs are the next commit. `main` has Days 1–3 (PR #4).
- **Last test totals the developer ran** (9 Nov, after all Step 8 fixes, both clean):
  `npm test` 1269, `npm run test:db` 545, contract 37 (with `--gas-stats`).

**Done on this branch** (docs updated for all of it):

- Seed script (`npm run seed`): first admin, demo GPS zone, demo users.
- Admin account endpoints (FR-10, FR-12): list, approve, reject, suspend, reactivate,
  reset-key.
- Signing: `docs/signing-spec.md` v1, `stepPayload`, `signatureService`, and the fixed
  vectors in `docs/signing-vectors.json` (never regenerate them).
- Device key registration (`PUT /auth/me/public-key`) and the unique-key migration.
- Sync (`POST /sync/steps`): registration, handoff and purchase; stage rules; deferral of
  out-of-order steps; bad signatures stored as flagged with an alert; per-user limiter;
  real-signature chain test.
- Step 8, anchoring (FR-03), done and proven live on Sepolia
  (`docs/live-run-2026-11-09.md`):
  - `src/chain/`: minimal ABI with a drift test, chain client (the only network code;
    primary and fallback RPC; secrets hidden), error classification, preflight;
  - `src/services/`: `anchorCall`, `anchorQueue` (eligibility, advisory lock),
    `anchorService.runOnce()` (reconcile, then one send; crash and error tables);
  - the worker timer in `server.js`, `anchor:once` and `demo:journey` (DEV-SHORTCUT);
  - migration `transactions-anchor-nonce`; sync's `received_at = clock_timestamp()` fix;
  - tests use `tests/fakes/fakeChainClient.js`; no test touches Sepolia.

**Next, in order:**

1. Step 9, the five anomaly rules. Plan first: turn `QR_CODE_ALREADY_REGISTERED` and
   `CONSIGNMENT_CLOSED` into flagged steps with alerts, add a `MESSAGES` entry for every
   new flagged code, set `zone_id`. Decide there whether anchoring failures raise an alert
   (they are only logged now).
2. GPS zones API (FR-11).
3. Then: CSV reports, officer and admin account creation, Render deploy, open the PR.

**Working rules that held all weekend:**

- Manual mode. Never run git. Never run tests unless asked.
- One sub-step at a time, and stop after each. "Plan only" first on new or risky work.
- Refusal tests take a function that starts the action, not a promise already started.
- Values from signed payloads stay as text, never JavaScript floats.
- Rejected and deferred items (sync steps, refused tokens and roles) are never audited.
- Check `docs/decisions.md` before changing any decided behaviour.
- Never open or read any `.env` file. The recorder key and RPC URLs are secrets: never
  logged, printed or put in an error.
- On PowerShell, run scripts that take flags with `node scripts/...`, not `npm run ... --`.

Known limits are listed in `docs/decisions.md`; they are not repeated here.

## Repo layout

| Path | Contents |
|---|---|
| `contracts/` | Solidity contract and tests (Hardhat 3) |
| `backend/` | Node.js REST API |
| `mobile/` | Flutter Android app |
| `docs/` | Architecture, API and contract specs, database schema, decisions log |
| `private/` | Git-ignored local documents |

`private/` must never be referenced in committed files: no quotes, links, paths or section
numbers. Read it locally for detail, then put what is needed in your own words. The only
exceptions are the ignore entry in `.gitignore` and this rule.

## Requirements summary

Priorities: **M** Must, **S** Should, **C** Could.

### Functional

| ID | Summary | Priority |
|---|---|---|
| FR-01 | Register a consignment by QR scan with GPS, mineral, weight, time | M |
| FR-02 | Sign each transaction with the user's ECDSA key | M |
| FR-03 | Record signed transactions on Sepolia through the contract | M |
| FR-04 | Verify a consignment by QR scan and signature check | M |
| FR-05 | Log full details and chain hash of every transaction for audit | M |
| FR-06 | JWT login and role-based access for all five roles | M |
| FR-07 | Cache offline in an encrypted database, sync on reconnect | M |
| FR-08 | Flag anomalies and push alerts to officers | M |
| FR-09 | Filtered transaction reports, exported as spreadsheets | M |
| FR-10 | Admin manages accounts and role permissions | M |
| FR-11 | Admin manages licensed GPS extraction zones | S |
| FR-12 | Users request accounts, admin approves | S |
| FR-13 | Officers download audit trails as spreadsheets | S |
| FR-14 | Analytics dashboard | C (cut) |
| FR-15 | Multi-language interface | C (cut) |
| FR-16 | Signed PDF provenance certificate | S |

FR-14 and FR-15 are cut unless time remains. Do not start them without being asked.

### Non-functional

| ID | Area | Summary | Priority |
|---|---|---|---|
| NFR-01 | Security | AES-256 at rest, TLS 1.3 with pinning, JWT valid 60 minutes at most | M |
| NFR-02 | Security | No Critical or High OWASP MSTG findings; private keys never leave the device | M |
| NFR-03 | Performance | Local save within 3s on a low-end device; sync within 10s on stable 3G | M |
| NFR-04 | Reliability | 72 hours offline with no data loss | M |
| NFR-05 | Scalability | At least 500 users across several zones | M |
| NFR-06 | Usability | Registration in three taps or fewer, plain language | S |
| NFR-07 | Maintainability | Faults fixable in four working hours; contract functions documented and emit events | S |
| NFR-08 | Data integrity | Detect and resolve offline sync conflicts without data loss | M |
| NFR-09 | Compatibility | Android 8.0 (API 26) or later, screens of 5 inches or larger | M |

## Approved decisions

Do not change these without asking. Record new decisions in `docs/`.

- **Contracts:** Hardhat 3.
- **Flutter state management:** Riverpod.
- **Local encrypted database:** SQLCipher. The package is still to be confirmed, so propose
  options with trade-offs rather than picking one.
- **Hosting:** Render, with PostgreSQL as the server database.
- **Ledger:** public Ethereum Sepolia. It is "permissioned" only through contract access
  control: anyone can read it, and only the authorised account can write. Never describe it
  as a private or permissioned chain.

## Teaching rules

The developer is a student learning while building.

- Explain the plan and the reason for it before writing code.
- Work in small steps, and stop at sensible points so the work can be read and tested.
- Comments explain why, not what.
- After major code, add a short **Learning notes** section in the reply covering what was
  built, why, and what to look at.
- Explain new concepts simply, with a concrete example, the first time they appear.
- Never generate huge files in one go. Build them up across steps.

## Security rules

- No secrets in code or Git: keys, JWT secrets, passwords, RPC URLs with API keys.
- `.env` files stay ignored. Commit `.env.example` with fake values only.
- Use a throwaway Sepolia wallet only, never one that has held real funds.
- ECDSA private keys live in the Android Keystore and never leave the device.
- Tokens go in secure storage, never in plain preferences or logs.
- Validate all input on the server, even if the app already validated it.
- Use parameterised queries only. Never build SQL by joining strings.
- Sepolia is public, so never put personal data on-chain. Store hashes and references.
- Mark any development shortcut so it can be found and removed:

  ```
  // DEV-SHORTCUT: <what this skips> | <what must replace it before release>
  ```

## Code structure

**Flutter:** organise by feature, each with its own layers.

```
mobile/lib/
  core/            shared theme, networking, helpers
  features/
    <feature>/
      data/          API calls, local database, repositories
      domain/        models and business rules, no Flutter imports
      presentation/  screens, widgets, Riverpod providers
```

**Backend:** requests flow in one direction.

```
backend/src/
  routes/        URLs mapped to controllers
  controllers/   read the request, call a service, send the response
  services/      business logic, including anomaly checks
  middleware/    authentication, role checks, validation, error handling
```

**Tests:** cover logic, key screens, the contract and the API.

- Contract: every function, including rejected unauthorised callers.
- Backend: service logic, especially each anomaly rule, plus API endpoints.
- Mobile: domain logic, sync and conflict handling, and widget tests for key screens.

## Git rules

- Never run `git commit`, `git push` or create branches. The developer does all Git
  operations.
- Read-only commands such as `git status`, `git diff` and `git log` are allowed.
- Before the developer commits, remind them to check for secrets.
- Use Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`.
- Suggest a commit message when a step is finished, but do not run it.

## Platform

- **Development:** Windows laptop with PowerShell. Give commands in PowerShell syntax.
- **Test device:** Samsung Galaxy A57 (Android 17).
- **Target:** Android only, so do not add iOS, web or desktop code.
