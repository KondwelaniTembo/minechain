# MineChain deployment

How the MineChain backend runs on Render: what was set up, in what order, how each part was
checked, and what to do before the presentation. The deployment was made on 12–14 November
2026. The reasons behind each choice are in [decisions.md](decisions.md), "Deployment
(1)–(12)".

This page holds no secret values, hostnames, URLs or IP addresses. Services are named by
their Render names, settings by their environment variable names, and RPC providers by
provider name.

---

## Overview

| Part | Where it runs |
|---|---|
| REST API and anchoring worker | Render web service **minechain-api** (Frankfurt, Free) |
| Server database | Render PostgreSQL **minechain-db** (Frankfurt, Free) |
| Ledger | The MineChain contract on Ethereum Sepolia, reached through Alchemy, with PublicNode as the fallback (from 22 Nov; before that PublicNode, with 1RPC as a fallback that never answered from Render) |
| Migrations, seed and backups | Run by hand from the developer's laptop, never on Render |

The API reaches the database over Render's private network. Clients reach the API through
Cloudflare and Render's own proxies. Anchoring runs in production only.

---

## Platform constraints

Checked in Render's documentation on 12 November 2026. These shape most of the decisions
below.

- **Free web services spin down** after 15 minutes without requests, and take about 50–60
  seconds to wake on the next one.
- **750 free instance hours** per workspace per month. An unrelated free service was
  suspended so that minechain-api stays within them.
- **The free PostgreSQL database expires 30 days after it is created.** It holds 1 GB, has
  no backups, and a workspace may have only one.
- **No shell and no one-off jobs** on free services, so migrations and the seed cannot run
  on Render.
- **The filesystem is ephemeral**: anything written to disk is lost at the next restart or
  deploy. The API writes nothing to disk.

---

## Services

### minechain-db

| Setting | Value |
|---|---|
| Engine | PostgreSQL 18 |
| Region and plan | Frankfurt, Free |
| Created | 12 November 2026, about 23:03 |
| Expires | about 12 December 2026 (30 days after creation) |
| Schema | All 11 migrations in `backend/migrations/`, applied from the laptop: 10 on 12–13 Nov, and `1794528000000_users-deleted` on 15 Nov ([Migrations after the first deploy](#migrations-after-the-first-deploy)) |
| Data at start | One active admin account and the demo GPS zone, from the production-admin-only seed; no demo users |

Render gives two connection strings. The **Internal URL** works only inside Render's private
network and is the one minechain-api uses. The **External URL** is for administration tools
on the laptop, which always connect with `sslmode=verify-full` (see
[Backups and restore](#backups-and-restore)).

### minechain-api

| Setting | Value |
|---|---|
| Region and plan | Frankfurt, Free |
| Root directory | `backend` |
| Build command | `npm ci` |
| Start command | `node src/server.js` |
| Health check path | `/health` |
| Auto-deploy | On every commit to `main` |
| Node version | 22.14.0, pinned in `backend/.node-version` (commit `044af61`) |
| In front of it | Cloudflare, then two Render proxies |

With node as the start command, the app process itself receives Render's SIGTERM, with no
npm process in between. That signal starts the graceful shutdown in `backend/src/server.js`:
the anchoring timer stops, open requests finish, and the database pool closes.

---

## Environment variables

Set on minechain-api in Render's Environment page. Values are written here only for the four
settings that are not secret.

| Name | Purpose | Secret | Where the value comes from |
|---|---|---|---|
| `NODE_ENV` | Production mode | No | `NODE_ENV=production` |
| `DATABASE_URL` | The database connection, including its password | Yes | minechain-db's **Internal URL**, copied from Render |
| `JWT_SECRET` | Signs and checks login tokens (HS256) | Yes | A new 64-character secret made for production, different from the development one |
| `JWT_EXPIRES_IN` | Token lifetime, at most 60 minutes (NFR-01) | No | `JWT_EXPIRES_IN=60m` |
| `TRUST_PROXY` | How many proxies sit in front of the app, so rate limits and audit entries see the real client address | No | `TRUST_PROXY=3`, measured (see [Verification](#trust_proxy)) |
| `ANCHOR_ENABLED` | Runs the anchoring worker in this process | No | `ANCHOR_ENABLED=true` |
| `MINECHAIN_CONTRACT_ADDRESS` | The deployed MineChain contract on Sepolia | No (public on-chain) | The deployment recorded in `docs/contract-spec.md` |
| `SEPOLIA_RPC_URL` | Primary RPC gateway | Yes (treated as secret, because RPC URLs can carry API keys) | Alchemy's Sepolia endpoint, from 22 Nov (it keeps receipts for the whole chain; see [Verification fix](#rpc-gateways-from-22-nov)) |
| `SEPOLIA_RPC_URL_FALLBACK` | Fallback RPC gateway | Yes (as above) | PublicNode's Sepolia endpoint, from 22 Nov (1RPC before) |
| `RECORDER_PRIVATE_KEY` | Signs the anchoring transactions | Yes | The throwaway recorder wallet that holds `RECORDER_ROLE` |

The anchoring settings not in this list (`CHAIN_ID`, `ANCHOR_INTERVAL_SECONDS`,
`ANCHOR_CONFIRMATIONS`, `ANCHOR_MAX_ATTEMPTS`, `ANCHOR_LOW_BALANCE_ETH`,
`ANCHOR_MAX_FEE_GWEI`) are not set, so the defaults in `backend/src/config.js` apply.

**The chain settings also drive verification.** `SEPOLIA_RPC_URL`,
`SEPOLIA_RPC_URL_FALLBACK` and `MINECHAIN_CONTRACT_ADDRESS` are read by two parts of the API,
not one:

- the anchoring worker, which also needs `RECORDER_PRIVATE_KEY` and runs only when
  `ANCHOR_ENABLED=true`;
- the consignment view's chain reader (`GET /consignments/by-qr/{qrCode}`), which needs no
  key and exists whenever `SEPOLIA_RPC_URL` and `MINECHAIN_CONTRACT_ADDRESS` are both set,
  **even with `ANCHOR_ENABLED=false`**. The fallback stays optional.

If either of the two is unset, the server still starts, with no chain reader. The start-up log
then says "Verification: no chain reader (RPC URL or contract address not set)", and every
consignment view reports its chain checks as `chain_unavailable`. A configured reader makes no
network call at start-up. On its first use of each endpoint it checks that the endpoint is on
Sepolia and that the code at the contract address has the expected hash (the constant in
`backend/src/chain/mineChainAbi.js`, the one the anchoring preflight also uses). A failed check
is logged with the endpoint's role only (primary or fallback) and also gives
`chain_unavailable`, never a tamper result.

Never on Render:

- **The contract deployer key.** It holds the admin role on the contract and stays on the
  laptop.
- **The seed variables** `SEED_ADMIN_USERNAME` and `SEED_ADMIN_PASSWORD`. The seed runs from
  the laptop, so they exist only in the terminal that runs it.

The development `backend/.env` keeps `ANCHOR_ENABLED=false`, so only production uses the
single recorder wallet.

---

## Deployment steps as performed

1. **12 Nov.** Read Render's free-tier limits ([Platform constraints](#platform-constraints)).
2. **12 Nov, about 23:03.** Created minechain-db (PostgreSQL 18, Frankfurt, Free).
3. **From the laptop, over the External URL with `sslmode=verify-full`:**
   - applied all 10 migrations;
   - **13 Nov:** ran the seed with `--production-admin-only`. It created one active admin
     account and the demo GPS zone, and wrote the `user.create` and `gps_zone.create` audit
     entries. It printed that demo users were skipped.

   On 13 Nov, on a mobile hotspot, the seed timed out twice ("Connection terminated due to connection
   timeout") and succeeded on the third attempt. Each failed run was rolled back, and the
   seed creates only rows that do not exist yet, so retrying was safe.
4. **13 Nov.** Created minechain-api with the settings in [Services](#minechain-api). Set
   the environment variables. `ANCHOR_ENABLED` was turned on only later, at step 7.
5. **13 Nov, 21:45.** First deploy, from commit `044af61`. The build took 44.7 s and
   installed 129 packages, with dev dependencies left out. The build log confirmed Node
   22.14.0.
6. **13–14 Nov.** Smoke tests, then the `TRUST_PROXY` measurement, then the TLS chain read
   ([Verification](#verification)).
7. **14 Nov, 20:35.** Enabled anchoring. Preflight passed, and the worker started ticking.
8. **14 Nov, 21:15.** First backup ([Backups and restore](#backups-and-restore)).
9. **15 Nov, about 22:30.** Backup, then migration `1794528000000_users-deleted`, before the
   branch that needs it was merged
   ([Migrations after the first deploy](#migrations-after-the-first-deploy)).

### Migrations after the first deploy

Merging to `main` deploys to Render automatically, and Render runs no migrations. A branch that
adds a migration therefore follows this order:

1. **Back up** production with `pg_dump` ([Backups and restore](#backups-and-restore)).
2. **Migrate production from the laptop**: `npm run migrate`, over the External URL with
   `sslmode=verify-full`.
3. **Confirm**: run `npm run migrate` again; it must say "No migrations to run!".
4. **Then merge.**

The migration has to stay compatible with the code still running from `main` until the merge
deploys the new code.

| Date | Migration | What was done |
|---|---|---|
| 15 Nov 2026, about 22:30 | `1794528000000_users-deleted` | Backup first, then `npm run migrate` applied it; a second run said "No migrations to run!". Production now has 11 migrations. The development database was already up to date. The branch was not merged yet, so Render was still running `main`. |

---

## Verification

### Smoke tests (13 Nov)

| Check | Result |
|---|---|
| `GET /health`, from a phone and from the laptop | `ok` |
| An unknown path | 404 |
| An admin route with no token | 401 |
| Security headers | Present: Content-Security-Policy, `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: no-referrer`, Cross-Origin-Opener-Policy and Cross-Origin-Resource-Policy `same-origin`, `Strict-Transport-Security: max-age=31536000; includeSubDomains`. No `X-Powered-By` |
| TLS 1.3 | A curl request limited to TLS 1.3 got 200, and .NET `SslStream` negotiated `Tls13` |
| Admin login, then `GET /admin/anchoring` | Both worked through the live API |

### TRUST_PROXY

**Method (13–14 Nov).** Log in while sending a forged `X-Forwarded-For: 203.0.113.7` (a
documentation address, RFC 5737). Then compare the `audit_logs.ip_address` recorded for that
login with the laptop's real public address. The comparison was made locally, and neither
address was shared or written down anywhere.

| `TRUST_PROXY` | Address recorded |
|---|---|
| 1 | A Render-internal private address |
| 2 | An address in Cloudflare's range |
| 3 | **The real client address** |
| 4 | Not set. By the same arithmetic it would record the forged value |

**Path reconstructed from this:** client, Cloudflare edge, two Render proxies, app. With 1 or
2, every client would share one rate-limit counter and the audit addresses would be
meaningless. With 4, a client could choose its own address. **3 is the only correct value
for this path, and it must be measured again whenever the hosting path changes.**

### TLS chain and pinning plan (14 Nov)

The chain served for the API:

| Level | Certificate | Expires | Notes |
|---|---|---|---|
| Leaf | Render's certificate | 21 Dec 2026 | Rotated by Render, so **never pinned** |
| Intermediate | WE1 (Google Trust Services) | 2029 | |
| Root | GlobalSign ECC Root CA – R4 | 2038 | WE1 also chains to **GTS Root R4**, so a phone may build either path |

**Pinning plan for the app:** trust only these three roots, through a `SecurityContext`
that holds nothing else:

- GTS Root R4;
- GlobalSign ECC Root CA – R4;
- ISRG Root X1, as the backup root.

The PEM files are taken from the CAs' official sources, and their fingerprints are checked
when they are added to the app. This carries out the 1 Nov pinning decision (root CA plus
backup root, never the server certificate).

### Anchoring preflight (14 Nov, 20:35)

- **Preflight passed:** chain id, contract code fingerprint and recorder role.
- **Recorder:** balance 0.009999 ETH, nonce 3. The nonce is unchanged since the 9 Nov live
  run ([live-run-2026-11-09.md](live-run-2026-11-09.md)), which also shows that the laptop
  is not anchoring.
- **Worker:** status `running`, `lastTick` `idle` every 30 s, `problems` empty.
- **Warning `rpcUnreachable` for the 1RPC fallback:**
  - it did not answer `eth_chainId` from Render, although it answers from a browser;
  - it had already refused `eth_sendRawTransaction` in the 9 Nov live run.

  1RPC stays configured. The code never drops an endpoint, reads move to the fallback only
  when the primary is unreachable (`RPC_UNAVAILABLE`, not a 401 or 403), and broadcasts go to
  every endpoint at once. In practice, production has **one** working RPC gateway,
  PublicNode. If PublicNode is down, anchoring pauses: steps stay `pending`, the worker backs
  off, and it resumes when PublicNode answers again.

### RPC gateways from 22 Nov

PublicNode keeps receipts and logs for only about the last 10,000 blocks (about 33 hours).
In the Reports T5 phone check, checking MC-2026-LSK-0008 therefore found no receipts for its
older steps and raised two false `record_tampered` alerts. Two changes followed (decisions
log, Verification fix (1) and (2)):

- **The code:** a missing receipt whose transaction is still in its block is
  `chain_unavailable`, not tampering (`fix/chain-check-pruned-receipts`).
- **Render's settings**, changed by the developer in the dashboard, never in Git:
  `SEPOLIA_RPC_URL` is Alchemy's Sepolia endpoint and `SEPOLIA_RPC_URL_FALLBACK` is
  PublicNode's. After the change, the service restarts. Check the logs for the worker's
  preflight passing and no `rpcUnreachable` warning, and check that `GET /admin/anchoring`
  shows `worker.state` `running`.
- **Then** an officer clears the two 0008 alerts with "Clear, no problem" and a reason. Until
  both changes are live, no consignment is checked on production: each step gets one tamper
  alert, ever (Verification (12)).

**Done 22–23 Nov:** PR #22 merged and deployed. On 22 Nov, about 22:30, the developer set
`SEPOLIA_RPC_URL` to Alchemy's Sepolia endpoint and `SEPOLIA_RPC_URL_FALLBACK` to
PublicNode's (replacing 1RPC) in Render's Environment page, and redeployed. The logs then
showed `Anchoring: enabled, running preflight`, `Verification: chain reader configured` and
`Anchoring preflight passed`, with no `rpcUnreachable` warning, so both endpoints answered
from Render (1RPC never had). The laptop's local `.env` was left unchanged: these settings
live only on Render. Checked on the A57 as `officer_demo` (23 Nov, 00:26–00:39):
MC-2026-LSK-0007 "Verified" with three steps matching the chain; 0008's registration and
handoff match, its rejected purchase was never anchored; the two false alerts were cleared
with a reason, and 0008 is no longer held.

---

## Operational security

- **Entering secrets.** Production secrets are entered only with `Read-Host -AsSecureString`,
  in a VS Code terminal used for nothing else, and that terminal is killed afterwards. The
  clipboard is cleared after a secret is copied.
- **Where secrets never go:** chat, screenshots or files in the repository. Render's
  Environment page shows values in plain text, so it is never captured.
- **IP addresses** are compared, never shared.
- **Never run any of these in a terminal holding production values:** the tests,
  `demo:journey`, `anchor:once`, or the normal seed (without `--production-admin-only`).
- **The recorder key** can be read by anyone with access to the Render account. The worst
  case is false anchors and spent test ETH. Mitigations:
  - two-factor login on GitHub and Render (the Render login goes through GitHub);
  - Render's GitHub app is limited to selected repositories;
  - the wallet holds little test ETH;
  - the deployer key is never on the server, and `RECORDER_ROLE` can be revoked from the
    laptop;
  - preflight confirmed that the key gives the expected recorder address.

---

## Backups and restore

The free database has **no automatic backups**, so backups are made by hand.

- **First backup, 14 Nov, 21:15:** `pg_dump` in custom format, 36,192 bytes, over a verified
  TLS connection. It is stored in a folder outside the repository.
- **Second backup, 15 Nov, about 22:30**, before the users-deleted migration: `pg_dump` in
  custom format, 36,192 bytes, over a verified TLS connection (`sslmode=verify-full`), stored
  outside the repository.
- **Trust store.** On Windows, psql and libpq with `sslrootcert=system` failed. The fix:
  export Node's 149 trusted root certificates to a PEM file and point `PGSSLROOTCERT` at it.
  `sslmode=verify-full` then checks the server's certificate and name.
  `sslmode=require` (encrypted, but unverified) is never used.
- **Routine:** run `pg_dump` after every important session.
- **Restore: not yet rehearsed.** A `pg_restore` rehearsal into a scratch local database is
  planned but has **not been done**. Until it is, a dump is not proven to restore.

---

## Presentation-window plan

The viva is on a weekday between 4 and 18 December 2026. minechain-db expires about 12
December, inside that window.

**Tuesday 1 December, database refresh:**

1. `pg_dump` the current database.
2. Delete the old free database. A workspace may have only one.
3. Create a new free database: Frankfurt, PostgreSQL 18.
4. `pg_restore` the dump. This keeps every row and id, so the anchors already on Sepolia
   still match their records.
5. Set the new database's Internal URL as `DATABASE_URL` on minechain-api.
6. Smoke test ([Verification](#smoke-tests-13-nov)).

**On presentation day:**

- Open `/health` 2–3 minutes before starting, to wake the service.
- Keep a recent dump and a screen recording of the full demo as fallbacks.

---

## Known limitations

Also recorded in [decisions.md](decisions.md), dated 14 Nov 2026.

- **The free database expires 30 days after creation**, hence the refresh on 1 December.
- **No automatic backups**, and the restore has not been rehearsed yet.
- **Cold start of about 50–60 s.** The first request after the service has been idle misses
  the 10-second sync target (NFR-03).
- **In-memory rate limits reset** whenever the service sleeps and wakes.
- **TLS 1.3 is enforced at Render's edge, not by the app**, so the mobile app must also
  require TLS 1.3 as its minimum.
- **The database connection inside Render's private network is not encrypted.**
- **Whole errors go to Render's logs**: `errorHandler` logs unexpected errors in full (Issue
  #3).
- **3 moderate `npm audit` findings** are still open (Issue #2).
- **The seed's short connection timeout** (the shared pool's 5 seconds, in `backend/src/db.js`)
  suits a server next to its database, not remote administration over a weak network.
- **The proxy hop count is specific to this path** and must be measured again if the hosting
  changes.
- ~~**Production effectively has one RPC gateway** (PublicNode).~~ From 22 Nov, Alchemy with
  PublicNode as the fallback ([RPC gateways from 22 Nov](#rpc-gateways-from-22-nov)).

---

## Re-check list after any hosting change

Run through all of these after any change to the region, plan, proxy, CDN or provider:

1. **`TRUST_PROXY`:** repeat the forged-header measurement ([TRUST_PROXY](#trust_proxy)) and
   set the value that records the real client address.
2. **TLS chain and pins:** read the served chain again, and check that it still ends at one
   of the three pinned roots. If not, update the app's roots **before** the server change
   reaches users.
3. **RPC reachability:** restart the service and read the "Anchoring preflight" line in
   Render's log. Check that it passed and look for `rpcUnreachable` warnings. Then check that
   `GET /admin/anchoring` shows the worker `running` with `problems` empty.
4. **`/health`:** `ok` from a phone and from the laptop.
