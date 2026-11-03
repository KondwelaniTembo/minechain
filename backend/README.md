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

3. Run the tests:

   ```powershell
   npm test
   ```

   Use `npm run test:watch` to re-run the tests automatically each time you save a file.

4. Start the API and check that it is running:

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
| `npm start` | Starts the API once. Render runs this |
| `npm test` | Runs the test suite once |
| `npm run test:watch` | Re-runs the tests on every save |

`GET /health` needs no login, so Render's health checks can reach it. It returns only
`up` or `down`.
