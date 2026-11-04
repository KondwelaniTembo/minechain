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

   `.env` is git-ignored. Never commit it.

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

   `npm test` runs the unit and API tests and needs no database. `npm run test:db` runs the
   database tests against `minechain_test`. It applies any pending migrations first, and
   rolls back every test, so it never leaves data behind. Use `npm run test:watch` to
   re-run the unit tests each time you save a file.

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

The schema, its rules and the reasons behind them are in
[docs/database-schema.md](../docs/database-schema.md).

`GET /health` needs no login, so Render's health checks will be able to reach it once
hosting is set up (planned). It returns only `up` or `down`.
