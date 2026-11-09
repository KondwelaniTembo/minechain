// `npm run anchor:once` (one tick) or `npm run anchor:once -- --until-idle`.
// The "--" matters: without it, npm takes the flag as its own option.
//
// Needs the chain settings in backend/.env (SEPOLIA_RPC_URL, MINECHAIN_CONTRACT_ADDRESS,
// RECORDER_PRIVATE_KEY) even with ANCHOR_ENABLED=false. If the server's worker is running
// too, the two share the advisory lock, and this one answers "busy".
//
// Exit codes: 0 idle, 1 a problem (see the last line), 2 bad arguments, 3 work remains.
// All the rules live in src/cli/anchorOnce.js; this file only connects things.
import dotenv from 'dotenv';
import { loadConfig } from '../src/config.js';
import { createPool, createDb } from '../src/db.js';
import { createChainClient } from '../src/chain/chainClient.js';
import { runPreflight } from '../src/chain/preflight.js';
import { createAnchorService } from '../src/services/anchorService.js';
import { describeError } from '../src/anchorWorker.js';
import { EXIT, UsageError, parseAnchorOnceArgs, runAnchorOnce, stepsFromDb } from '../src/cli/anchorOnce.js';

dotenv.config({ quiet: true });

async function main() {
  let options;
  try {
    options = parseAnchorOnceArgs(process.argv.slice(2));
  } catch (err) {
    if (err instanceof UsageError) {
      console.error(err.message);
      return EXIT.USAGE;
    }
    throw err;
  }

  let config;
  try {
    config = loadConfig(process.env, { requireChain: true });
  } catch (err) {
    // Variable names and rules only, never values.
    console.error(err.message);
    return EXIT.USAGE;
  }

  const pool = createPool(config.databaseUrl);
  const db = createDb(pool);
  const chain = createChainClient(config.anchor);
  try {
    const service = createAnchorService({ db, pool, chain, config: config.anchor });
    return await runAnchorOnce({
      options,
      preflight: () => runPreflight(chain, config.anchor),
      runOnce: service.runOnce,
      steps: stepsFromDb(db),
      sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    });
  } catch (err) {
    console.error(`anchor:once failed: ${describeError(err)}`);
    return EXIT.PROBLEM;
  } finally {
    chain.close();
    await db.close();
  }
}

// exitCode rather than process.exit(), so the pool finishes closing before Node exits.
process.exitCode = await main();
