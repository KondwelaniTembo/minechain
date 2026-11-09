// DEV-SHORTCUT: server-side signing of a demo custody chain | remove before release (see src/cli/demoJourney.js)
//
// `npm run demo:journey`: creates three fresh demo users and syncs a registration, handoff
// and purchase for a new QR code through the real services. Development only. All the
// rules live in src/cli/demoJourney.js; this file only connects things.
import dotenv from 'dotenv';
import { loadConfig } from '../src/config.js';
import { createPool, createDb } from '../src/db.js';
import { createServices } from '../src/services/index.js';
import { describeError } from '../src/anchorWorker.js';
import { DemoJourneyError, assertDemoAllowed, runDemoJourney } from '../src/cli/demoJourney.js';

dotenv.config({ quiet: true });

async function main() {
  if (process.argv.length > 2) {
    console.error('demo:journey takes no arguments.');
    return 2;
  }
  let config;
  try {
    config = loadConfig(process.env);
  } catch (err) {
    console.error(err.message);
    return 2;
  }
  try {
    // Checked before connecting, so a refused run never opens the database.
    assertDemoAllowed(config.nodeEnv);
  } catch (err) {
    console.error(err.message);
    return 1;
  }

  const db = createDb(createPool(config.databaseUrl));
  try {
    await runDemoJourney({ db, services: createServices({ db, config }), nodeEnv: config.nodeEnv });
    return 0;
  } catch (err) {
    console.error(err instanceof DemoJourneyError ? err.message : `demo:journey failed: ${describeError(err)}`);
    return 1;
  } finally {
    await db.close();
  }
}

process.exitCode = await main();
