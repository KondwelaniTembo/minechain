# backend/

Node.js REST API: JWT authentication, role-based access, transaction processing and anomaly detection.

## Setup

You need Node.js 22 or later and a local PostgreSQL server. Run these commands in PowerShell
from the `backend/` folder.

1. Install the dependencies:

   ```powershell
   npm install
   ```

   `backend/.npmrc` sets `legacy-peer-deps=true`. Without it, npm 10.9.2 crashes while
   installing vitest 5 with `Cannot read properties of null (reading 'edgesOut')`. The
   setting is picked up automatically, so you do not need to add `--legacy-peer-deps`
   yourself. The cost is that npm no longer installs required peer dependencies. That is
   why `vite`, which vitest needs, is listed directly in `devDependencies`. Run `npm ls`
   after adding a package to catch any other missing peers.

2. Create your local environment file and replace every placeholder value:

   ```powershell
   Copy-Item .env.example .env
   ```

   `.env` is git-ignored. Never commit it. Two values need care:

   - `JWT_SECRET` must be at least 43 random characters (256 bits for HS256). Generate one
     with the command shown in `.env.example`; it gives 64 characters.
   - `TRUST_PROXY` is the number of proxies in front of the API. Keep it at `0` locally.
     Hosting on Render is planned, and is expected to need `1`. It is a count of hops, never
     `true`: the rate limits and the audit log's IP addresses rely on Express taking the
     client address from our own proxy, not from a header the client could forge. With `0`,
     a request that arrives with an `X-Forwarded-For` header makes express-rate-limit log an
     `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR` warning. In production, that would mean
     `TRUST_PROXY` is set wrong.

3. Create the two databases and apply the migrations. Skip the first three commands if
   the role and databases already exist. `createuser --pwprompt` asks for the password, so
   it never appears in your command history. Use the same name and password as in `.env`.

   ```powershell
   createuser -U postgres --pwprompt minechain_app
   createdb -U postgres -O minechain_app minechain_dev
   createdb -U postgres -O minechain_app minechain_test
   npm run migrate
   npm run migrate:test
   ```

4. Run the tests:

   ```powershell
   npm test
   npm run test:db
   ```

   There are two suites, and both should pass before every commit:

   | Suite | Command | Needs | Covers |
   |---|---|---|---|
   | Unit and API | `npm test` | Nothing: no database, no network | Services with fake dependencies, middleware, and every endpoint through Supertest |
   | Database | `npm run test:db` | PostgreSQL running, and `TEST_DATABASE_URL` in `.env` | The schema's rules, the services against real tables, and each endpoint through the real stack |

   `npm run test:db` applies any pending migrations to `minechain_test` first. It runs each
   test inside a transaction that is rolled back afterwards, so it never leaves data behind,
   and it never touches `minechain_dev`. Use `npm run test:watch` to re-run the unit suite
   each time you save a file.

5. Start the API and check that it is running:

   ```powershell
   npm run dev
   ```

   In a second terminal:

   ```powershell
   curl.exe -i http://localhost:3000/health
   ```

   `200` with `"database":"up"` means the API reached PostgreSQL. `503` with
   `"database":"down"` means the API is running but cannot reach the database. In that
   case, check `DATABASE_URL` and that the database exists. Press Ctrl+C to stop the server.

6. Seed the first admin, the demo GPS zone and the demo users (see [Seeding](#seeding)):

   ```powershell
   npm run seed
   ```

## Seeding

`npm run seed` creates what an empty database needs before anyone can log in:

| What | When |
|---|---|
| The first admin, from `SEED_ADMIN_USERNAME` and `SEED_ADMIN_PASSWORD` | Always |
| The GPS zone "ZCAS Campus (demo)", owned by that admin | Always |
| One active user per role: `seed_miner`, `seed_transporter`, `seed_buyer`, `seed_officer`, all with `SEED_DEMO_PASSWORD` | Only outside production, and only when `SEED_DEMO_PASSWORD` is set |

Before the first run:

1. Set `SEED_ADMIN_USERNAME`, `SEED_ADMIN_PASSWORD` and, if you want demo users,
   `SEED_DEMO_PASSWORD` in `.env`. Both passwords must meet the registration password policy.
2. Fill in `ZCAS_CAMPUS_BOUNDARY` in `src/seed/seedData.js`: at least 3 corners in
   **`[latitude, longitude]`** order, with at most 6 decimal places each. The comment there
   shows an example. While it is empty, the seed refuses to run.

It is safe to run again. Existing users and zones are matched by name in any letter case
and never changed, so a second run prints `0 created` and reports everything as already
existing. Everything is saved in one transaction, so a failed run saves nothing. Each row
created gets a `user.create` or `gps_zone.create` audit entry with `"source": "seed"`. The
passwords are never printed.

**In production** (`NODE_ENV=production`) the seed refuses to run unless you pass
`--production-admin-only`, which creates only the admin and the zone:

```powershell
npm run seed -- --production-admin-only
```

The `--` is required. Without it, npm takes the flag as its own option, the script never
sees it, and the seed refuses to run. The seed also refuses `NODE_ENV=test`, because the
database tests call it directly.

**On PowerShell**, npm's shim can drop the `--` itself (seen with `anchor:once`; see the
decisions log, 9 Nov). Calling the script directly always passes the flag:

```powershell
node scripts/seed.js --production-admin-only
```

## Anchoring

The anchoring worker writes each accepted step to the MineChain contract on Sepolia. How it
decides what to send, and how it recovers from crashes, is in
[docs/database-schema.md](../docs/database-schema.md#anchoring). The first live run is
recorded in [docs/live-run-2026-11-09.md](../docs/live-run-2026-11-09.md).

**Settings** (in `.env`; see `.env.example` for every one, with fake values):

- `SEPOLIA_RPC_URL`, `SEPOLIA_RPC_URL_FALLBACK` (optional) and `RECORDER_PRIVATE_KEY` are
  **secrets**: the URLs carry the provider's API key. The key must be the throwaway recorder
  wallet's, never the deployer's or the admin's. Never use the recorder wallet by hand: the
  worker owns its nonces.
- `MINECHAIN_CONTRACT_ADDRESS`, `CHAIN_ID` (only 11155111 is accepted), and the tuning
  values `ANCHOR_INTERVAL_SECONDS`, `ANCHOR_CONFIRMATIONS`, `ANCHOR_MAX_ATTEMPTS`,
  `ANCHOR_LOW_BALANCE_ETH` and `ANCHOR_MAX_FEE_GWEI`.
- `ANCHOR_ENABLED=true` starts the worker inside the API (`npm run dev` or `npm start`). It
  checks the chain once at startup (right chain, right contract code, recorder role) and
  logs one line. If a check fails, the worker does not start, but the API still does.

**Scripts.** Use `node scripts/...` on PowerShell, so that flags reach the script:

| Command | What it does |
|---|---|
| `node scripts/anchor-once.js` | Runs the startup checks and prints them (recorder address, balance, warnings), then one anchoring tick, with an Etherscan link for anything sent or confirmed. Needs the chain settings even while `ANCHOR_ENABLED=false` |
| `node scripts/anchor-once.js --until-idle` | Keeps ticking, 15 s apart and for at most 10 minutes, until nothing is left to anchor. It stops early, and says why, if the wallet lost its role, sending is paused, another process holds the anchoring lock, or a submitted step is stuck |
| `node scripts/demo-journey.js` | Development only (refuses `production` and `test`). Creates three fresh demo users with in-memory keys, then signs and syncs a registration, handoff and purchase for a new QR code through the real sync pipeline, so there is something to anchor. Never touches the `seed_*` users. Marked `DEV-SHORTCUT` |

`anchor:once` exit codes: `0` idle; `1` a problem (the last line says which); `2` an unknown
argument or invalid settings; `3` one tick ran normally but work remains.

A typical demo, from `backend/`:

```powershell
node scripts/demo-journey.js
node scripts/anchor-once.js --until-idle
```

If the server's worker is running at the same time, `anchor-once` answers "busy": only one
process anchors at a time.

## Scripts

| Script | What it does |
|---|---|
| `npm run dev` | Starts the API and restarts it whenever a file changes (`node --watch`) |
| `npm start` | Starts the API once. Render will run this (planned) |
| `npm test` | Runs the unit and API tests once (no database needed) |
| `npm run test:watch` | Re-runs the unit and API tests on every save |
| `npm run test:db` | Runs the database tests against `TEST_DATABASE_URL` |
| `npm run migrate` | Applies pending migrations to `DATABASE_URL` |
| `npm run migrate:test` | Applies pending migrations to `TEST_DATABASE_URL` |
| `npm run migrate:down` | Rolls back the latest migration on `DATABASE_URL` (add `-- 2` for two) |
| `npm run migrate:create -- <name>` | Creates a new SQL migration file in `migrations/` |
| `npm run seed` | Creates the first admin, the demo zone and demo users (see [Seeding](#seeding)). Add `-- --production-admin-only` in production |
| `npm run anchor:once` | One anchoring tick, with the startup checks printed. On PowerShell use `node scripts/anchor-once.js [--until-idle]` (see [Anchoring](#anchoring)) |
| `npm run demo:journey` | Development only: a demo custody chain to anchor (see [Anchoring](#anchoring)) |

## Documentation

- [docs/api.md](../docs/api.md): every endpoint (`/health`, `/auth/register`,
  `/auth/login`, `/auth/me`, `/auth/me/public-key`, `/sync/steps` and the `/admin/users` account endpoints), with request bodies,
  examples, error codes and rate limits.
- [docs/database-schema.md](../docs/database-schema.md): the schema, its rules and the
  reasons behind them.
- [docs/decisions.md](../docs/decisions.md): the decisions log, including the known
  limitations of the current authentication and of anchoring.
- [docs/contract-spec.md](../docs/contract-spec.md): the MineChain contract, including the
  measured gas per write.
- [docs/live-run-2026-11-09.md](../docs/live-run-2026-11-09.md): the first anchoring run on
  Sepolia, with its Etherscan links.

`GET /health` needs no login, so Render's health checks will be able to reach it once
hosting is set up (planned). It returns only `up` or `down`.
