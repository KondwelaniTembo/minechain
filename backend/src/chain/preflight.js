// Startup checks for the anchoring worker (8 Nov plan, step 8). They run against a chain
// client, real or fake, and return a structured result; the caller decides what to log.
//
// Checks 1 to 3 decide whether the worker may start at all:
//   1. chainId  every configured RPC reports the configured chain
//   2. code     the contract address holds exactly the deployed MineChain bytecode
//   3. role     the contract's RECORDER_ROLE is the expected one, and the wallet holds it
// After those, the balance and nonces give warnings, and decide whether sending can begin.
//
// No network code here: keccak256 and id are pure hash functions.
import { id, keccak256 } from 'ethers';
import { ChainClientError } from './chainClient.js';
import { EXPECTED_CODE_HASH } from './mineChainAbi.js';

export const EXPECTED_RECORDER_ROLE = id('RECORDER_ROLE');

// Gas for the most expensive step, used only to judge whether the balance can pay for one
// more transaction (sending itself checks the balance against the real estimate).
// Measured in the live run on 9 Nov 2026 (docs/live-run-2026-11-09.md): registerConsignment
// used 352,951 gas, handoff 59,299 and purchase 59,182. Registration is that much dearer
// because Sepolia runs Glamsterdam, whose EIP-8037 charges state gas for creating storage:
// each 0 -> non-zero SSTORE costs 64 state bytes x 1,530 = 97,920 extra, and a registration
// creates 3 slots (352,951 - 3 x 97,920 = 59,191, the cost of a handoff). Under the older
// Osaka rules it was 96,645 (npx hardhat test --gas-stats). EIP-8037 is still in Review, so
// the price per state byte may change; 450,000 leaves about a quarter in hand.
export const MAX_GAS_PER_STEP = 450_000n;

function passed(name) {
  return Object.freeze({ name, status: 'passed' });
}

function failed(name, problem) {
  return Object.freeze({ name, status: 'failed', problem });
}

// Only a ChainClientError's message is passed on: it is built from fixed text. Any other
// error is a bug here or in the client, and its message could contain anything.
function messageOf(err) {
  return err instanceof ChainClientError ? err.message : 'an unexpected error';
}

function codeOf(err) {
  return err instanceof ChainClientError ? err.code : 'UNKNOWN';
}

// The check could not be made, usually because no RPC answered. Not a verdict about the
// configuration, so the caller can try again later.
function errored(name, err) {
  return Object.freeze({ name, status: 'error', problem: messageOf(err), errorCode: codeOf(err) });
}

function skipped(name) {
  return Object.freeze({ name, status: 'skipped', problem: 'an earlier check did not pass' });
}

function warning(name, message) {
  return Object.freeze({ name, message });
}

async function checkChainIds(client, expected, warnings) {
  let answered = 0;
  for (const { name, host } of client.endpointHosts) {
    let actual;
    try {
      actual = await client.getChainId(name);
    } catch (err) {
      warnings.push(warning('rpcUnreachable', `${name} RPC ${host} did not answer: ${messageOf(err)}`));
      continue;
    }
    answered += 1;
    // A wrong chain on any endpoint is fatal, the fallback included: the worker would read
    // receipts and consignments from a chain it does not write to.
    if (actual !== expected) {
      return failed('chainId', `${name} RPC ${host} is on chain ${actual}, not ${expected}`);
    }
  }
  if (answered === 0) {
    return Object.freeze({
      name: 'chainId',
      status: 'error',
      problem: 'no configured RPC answered',
      errorCode: 'RPC_UNAVAILABLE',
    });
  }
  return passed('chainId');
}

async function checkCode(client) {
  const code = await client.getCode(client.contractAddress);
  if (code === '0x') return failed('code', 'there is no contract at MINECHAIN_CONTRACT_ADDRESS');
  if (keccak256(code) !== EXPECTED_CODE_HASH) {
    return failed('code', 'the contract at MINECHAIN_CONTRACT_ADDRESS is not the deployed MineChain');
  }
  return passed('code');
}

async function checkRole(client) {
  const role = await client.getRecorderRole();
  if (role.toLowerCase() !== EXPECTED_RECORDER_ROLE) {
    return failed('role', 'the contract reports an unexpected RECORDER_ROLE value');
  }
  if (!(await client.hasRole(role, client.recorderAddress))) {
    return failed('role', `the recorder wallet ${client.recorderAddress} does not hold RECORDER_ROLE`);
  }
  return passed('role');
}

// anchorConfig gives lowBalanceWei, maxFeePerGasWei and chainId.
//
// Result:
//   startable  checks 1 to 3 passed; the worker may run
//   canSend    startable, and the balance pays for at least one transaction
//   checks     one entry per check: passed, failed, error (could not check) or skipped
//   warnings   things a person should look at, none of which stops the worker
//   facts      what was read, for the startup log line; only public values
export async function runPreflight(client, anchorConfig) {
  const warnings = [];
  const checks = [];

  const steps = [
    ['chainId', () => checkChainIds(client, anchorConfig.chainId, warnings)],
    ['code', () => checkCode(client)],
    ['role', () => checkRole(client)],
  ];
  for (const [name, run] of steps) {
    // Later checks mean nothing once one has not passed: code on the wrong chain, or a role
    // on the wrong contract, would only be misleading.
    if (checks.some((c) => c.status !== 'passed')) {
      checks.push(skipped(name));
      continue;
    }
    try {
      checks.push(await run());
    } catch (err) {
      checks.push(errored(name, err));
    }
  }

  const startable = checks.every((c) => c.status === 'passed');
  const facts = { recorderAddress: client.recorderAddress };
  let canSend = false;

  if (startable) {
    try {
      const balanceWei = await client.getBalance();
      const latestNonce = await client.getNonce('latest');
      const pendingNonce = await client.getNonce('pending');
      const fees = await client.getFeeData();
      // The fee the worker would actually offer: the network's, but never above the cap.
      const feePerGas = fees.maxFeePerGas < anchorConfig.maxFeePerGasWei ? fees.maxFeePerGas : anchorConfig.maxFeePerGasWei;
      const oneTransactionWei = MAX_GAS_PER_STEP * feePerGas;
      Object.assign(facts, { balanceWei, latestNonce, pendingNonce, oneTransactionWei });

      canSend = balanceWei >= oneTransactionWei;
      if (!canSend) {
        warnings.push(warning('cannotAffordTransaction', 'the recorder wallet cannot pay for one transaction; sending is paused until it is topped up'));
      } else if (balanceWei < anchorConfig.lowBalanceWei) {
        warnings.push(warning('lowBalance', 'the recorder wallet balance is below ANCHOR_LOW_BALANCE_ETH; top it up from a Sepolia faucet'));
      }
      if (pendingNonce !== latestNonce) {
        // The worker reconciles its own submitted rows; this warns about the case it cannot
        // explain, such as the wallet having been used by hand.
        warnings.push(
          warning('pendingTransactions', `${pendingNonce - latestNonce} transaction(s) from the recorder wallet are waiting to be mined`),
        );
      }
      if (fees.maxFeePerGas > anchorConfig.maxFeePerGasWei) {
        warnings.push(warning('feeAboveMaximum', 'the network fee is above ANCHOR_MAX_FEE_GWEI; sending waits until it falls'));
      }
    } catch (err) {
      // Started but cannot yet tell whether it can pay: the worker waits and asks again.
      warnings.push(warning('balanceUnknown', `the balance and nonces could not be read: ${messageOf(err)}`));
    }
  }

  return Object.freeze({
    startable,
    canSend,
    checks: Object.freeze(checks),
    warnings: Object.freeze(warnings),
    facts: Object.freeze(facts),
  });
}
