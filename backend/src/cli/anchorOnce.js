// npm run anchor:once [-- --until-idle]: preflight, then one anchoring tick (or ticks until
// idle), printed for a person at a terminal. For the manual live run on Sepolia and for
// looking at the queue when the server's worker is off. The rules live here so tests can
// reach them; scripts/anchor-once.js only connects things.
//
// Prints only public values: check names and results, warnings, the recorder address, the
// balance, step ids, and Etherscan links. Never an RPC URL or the key: nothing here ever
// receives them.
import { etherscanTxUrl, preflightLines } from '../chain/describe.js';

export const UNTIL_IDLE_FLAG = '--until-idle';
export const TICK_SPACING_SECONDS = 15;
export const MAX_RUN_SECONDS = 10 * 60;
// A healthy submitted row is mined, or resent (which refreshes anchor_submitted_at), within
// a few minutes. One older than this is not moving: its resend dry run keeps being refused
// or the fee is above the cap. While it stays submitted, nothing else can be anchored.
export const STUCK_AFTER_SECONDS = 5 * 60;

export const EXIT = Object.freeze({
  IDLE: 0, //        nothing left to anchor
  PROBLEM: 1, //     not startable, stopped, paused, busy, stuck, or gave up waiting
  USAGE: 2, //       unknown argument
  NOT_IDLE_YET: 3, // one tick ran normally, but work remains (run again or use --until-idle)
});

export class UsageError extends Error {}

export function parseAnchorOnceArgs(args) {
  const unknown = args.filter((arg) => arg !== UNTIL_IDLE_FLAG);
  if (unknown.length > 0) {
    // A misspelt flag must not be ignored: the run would quietly do something else.
    throw new UsageError(`Unknown argument(s): ${unknown.join(' ')}. The only option is ${UNTIL_IDLE_FLAG}.`);
  }
  return Object.freeze({ untilIdle: args.includes(UNTIL_IDLE_FLAG) });
}

const toHex = (bytes) => (bytes ? `0x${Buffer.from(bytes).toString('hex')}` : null);

// What the script reads from the database to explain a tick. Hashes come back as hex.
export function stepsFromDb(db) {
  return Object.freeze({
    async submitted() {
      const { rows } = await db.query(
        `SELECT id, chain_tx_hash, anchor_submitted_at FROM transactions
          WHERE anchor_status = 'submitted' ORDER BY anchor_nonce, id`,
      );
      return rows.map((r) => ({ ...r, chain_tx_hash: toHex(r.chain_tx_hash) }));
    },
    async byIds(ids) {
      if (ids.length === 0) return [];
      const { rows } = await db.query('SELECT id, anchor_status, chain_tx_hash FROM transactions WHERE id = ANY($1::uuid[])', [ids]);
      return rows.map((r) => ({ ...r, chain_tx_hash: toHex(r.chain_tx_hash) }));
    },
  });
}

// options: parseAnchorOnceArgs's result. preflight: () => preflight result. runOnce: the
// anchoring service's tick. steps: stepsFromDb(db) or a fake. print: one line at a time.
// sleep and now are injectable so tests never wait. Returns the exit code.
export async function runAnchorOnce({ options, preflight, runOnce, steps, print = console.log, sleep, now = () => new Date() }) {
  const result = await preflight();
  for (const line of preflightLines(result)) print(line);
  if (!result.startable) return EXIT.PROBLEM;

  const deadline = now().getTime() + MAX_RUN_SECONDS * 1000;
  for (let tickNumber = 1; ; tickNumber += 1) {
    const before = await steps.submitted();
    const summary = await runOnce();
    const r = summary.reconciled;
    print('');
    print(
      `Tick ${tickNumber}: ${summary.outcome}${summary.code ? ` (${summary.code})` : ''}${summary.stepId ? `, step ${summary.stepId}` : ''}` +
        ` [confirmed ${r.confirmed}, waiting ${r.waiting}, resent ${r.resent}, back to pending ${r.returnedToPending}, failed ${r.failed}]`,
    );

    // Links for everything that was in flight or touched this tick.
    const ids = [...new Set([...before.map((s) => s.id), ...(summary.stepId ? [summary.stepId] : [])])];
    for (const step of await steps.byIds(ids)) {
      if (!step.chain_tx_hash) continue;
      if (step.anchor_status === 'confirmed' || step.anchor_status === 'submitted') {
        const label = step.anchor_status === 'confirmed' ? 'confirmed' : 'in flight';
        print(`  ${label.padEnd(9)} ${step.id}: ${etherscanTxUrl(step.chain_tx_hash)}`);
      }
    }

    // A stuck row blocks all anchoring (one transaction in flight), so it is said loudly.
    const stuckBefore = now().getTime() - STUCK_AFTER_SECONDS * 1000;
    const stuck = (await steps.submitted()).filter((s) => s.anchor_submitted_at.getTime() < stuckBefore);
    if (stuck.length > 0) {
      for (const s of stuck) {
        print(
          `STUCK: step ${s.id} has been submitted since ${s.anchor_submitted_at.toISOString()} and is not moving ` +
            '(its resend is refused or the fee is above ANCHOR_MAX_FEE_GWEI; see the warning above). ' +
            'Nothing else can be anchored until it is resolved.',
        );
        if (s.chain_tx_hash) print(`  last hash: ${etherscanTxUrl(s.chain_tx_hash)}`);
      }
      return EXIT.PROBLEM;
    }

    switch (summary.outcome) {
      case 'idle':
        print('Idle: nothing is waiting to be anchored.');
        return EXIT.IDLE;
      case 'stopped':
        print('Stopped: the recorder wallet does not hold RECORDER_ROLE. Fix the role first.');
        return EXIT.PROBLEM;
      case 'paused':
        print(`Paused (${summary.code}): nothing can be sent until that changes.`);
        return EXIT.PROBLEM;
      case 'busy':
        print('Busy: another process (probably the server\'s worker) holds the anchoring lock.');
        return EXIT.PROBLEM;
      default:
        break; // sent, waiting, refused, backoff: work goes on
    }

    if (!options.untilIdle) {
      print(`Not idle yet. Run it again, or use ${UNTIL_IDLE_FLAG}.`);
      return EXIT.NOT_IDLE_YET;
    }
    if (now().getTime() + TICK_SPACING_SECONDS * 1000 > deadline) {
      print(`Gave up after ${MAX_RUN_SECONDS / 60} minutes without reaching idle.`);
      return EXIT.PROBLEM;
    }
    await sleep(TICK_SPACING_SECONDS * 1000);
  }
}
