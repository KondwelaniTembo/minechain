import dotenv from 'dotenv';
import { loadConfig } from './config.js';
import { createPool, createDb } from './db.js';
import { createApp } from './app.js';
import { createServices } from './services/index.js';
import { createAnchorWorkerFromConfig, describeError } from './anchorWorker.js';

// Loads backend/.env into process.env for local development. On Render there is no .env
// file, and the variables come from the dashboard instead, so this quietly does nothing.
dotenv.config({ quiet: true });

let config;
try {
  config = loadConfig(process.env);
} catch (err) {
  // The message already lists every problem, so a stack trace would only add noise.
  console.error(err.message);
  process.exit(1);
}

const pool = createPool(config.databaseUrl);
const db = createDb(pool);
const app = createApp({ db, services: createServices({ db, config }), trustProxyHops: config.trustProxyHops });

// Only when ANCHOR_ENABLED is true. The worker needs the pool itself for its advisory lock,
// which must sit on a connection of its own.
const anchorWorker = config.anchor.enabled
  ? createAnchorWorkerFromConfig({ db, pool, anchorConfig: config.anchor })
  : null;

const server = app.listen(config.port, () => {
  console.log(`MineChain API listening on http://localhost:${config.port} (${config.nodeEnv})`);
  console.log(anchorWorker ? 'Anchoring: enabled, running preflight' : 'Anchoring: disabled (ANCHOR_ENABLED is not true)');
  // Not awaited: the API serves requests whatever the worker's preflight finds.
  anchorWorker?.start().catch((err) => console.error(`Anchoring worker could not start: ${describeError(err)}`));
});

// For example EADDRINUSE when another process already uses the port. Exiting with a clear
// message beats an unhandled 'error' event.
server.on('error', (err) => {
  console.error(`Server could not start: ${err.message}`);
  process.exit(1);
});

// Render sends SIGTERM before stopping or redeploying the service; Ctrl+C sends SIGINT.
// Requests already running get to finish, and the database pool closes its connections
// instead of leaving them open on the PostgreSQL side.
const SHUTDOWN_TIMEOUT_MS = 10_000;
let shuttingDown = false;

function shutdown(signal) {
  // A second Ctrl+C must not start a second shutdown.
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`${signal} received, shutting down`);

  // If a request never finishes, exit anyway rather than hang until the platform kills us.
  // unref() stops this timer from keeping the process alive by itself.
  setTimeout(() => {
    console.error('Shutdown took too long, forcing exit');
    process.exit(1);
  }, SHUTDOWN_TIMEOUT_MS).unref();

  // The worker's timer stops at once, so no new tick begins while requests drain. A tick
  // already running is waited for below, before the pool closes under it.
  const workerStopped = anchorWorker ? anchorWorker.stop() : Promise.resolve();

  // Stop accepting new connections and wait for open requests to finish.
  server.close(async (serverErr) => {
    try {
      await workerStopped;
      await db.close();
    } catch (dbErr) {
      console.error('Closing the database pool failed:', dbErr.message);
      process.exit(1);
    }
    if (serverErr) {
      console.error('Closing the HTTP server failed:', serverErr.message);
      process.exit(1);
    }
    console.log('Shutdown complete');
    process.exit(0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
