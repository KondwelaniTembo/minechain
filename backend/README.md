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

## Documentation

- [docs/api.md](../docs/api.md): every endpoint (`/health`, `/auth/register`,
  `/auth/login`, `/auth/me`), with request bodies, examples, error codes and rate limits.
- [docs/database-schema.md](../docs/database-schema.md): the schema, its rules and the
  reasons behind them.
- [docs/decisions.md](../docs/decisions.md): the decisions log, including the known
  limitations of the current authentication.

`GET /health` needs no login, so Render's health checks will be able to reach it once
hosting is set up (planned). It returns only `up` or `down`.
