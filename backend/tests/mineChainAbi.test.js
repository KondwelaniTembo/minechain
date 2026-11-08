import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Interface, keccak256 } from 'ethers';
import {
  MINECHAIN_ABI,
  SEPOLIA_CHAIN_ID,
  DEPLOY_BLOCK,
  EXPECTED_CODE_HASH,
} from '../src/chain/mineChainAbi.js';

// Only this test reads contracts/. The Ignition deployment folder is committed and records
// what is actually on Sepolia; contracts/artifacts/ is git-ignored and follows the current
// source, which could have moved on since the deployment.
const DEPLOYMENT_DIR = new URL('../../contracts/ignition/deployments/chain-11155111/', import.meta.url);
const FUTURE_ID = 'MineChainModule#MineChain';

function readDeploymentFile(name) {
  // A file path, not a URL: in a URL '#' starts a fragment, so new URL() would cut
  // 'MineChainModule#MineChain.json' at the '#'. In a path it is an ordinary character.
  return readFileSync(join(fileURLToPath(DEPLOYMENT_DIR), name), 'utf8');
}

const artifact = JSON.parse(readDeploymentFile(`artifacts/${FUTURE_ID}.json`));
const deployed = new Interface(artifact.abi);
const ours = new Interface(MINECHAIN_ABI);

// The fragments ethers parsed, in the order written, so a failure names the exact line.
const ourFragments = ours.fragments;

// The deployed fragment with the same kind and name, or undefined. MineChain overloads no
// names, so kind plus name identifies a fragment uniquely.
function deployedFragment(fragment) {
  return deployed.fragments.find((f) => f.type === fragment.type && f.name === fragment.name);
}

describe('MINECHAIN_ABI against the deployed artifact', () => {
  it('parses every line, so no typo was silently dropped', () => {
    // A line ethers cannot parse throws in new Interface above; this also catches a
    // duplicate line, which ethers would merge into one fragment.
    expect(ourFragments).toHaveLength(MINECHAIN_ABI.length);
  });

  it('contains exactly the fragments the anchoring worker needs', () => {
    // A guard against someone trimming a line the worker relies on, or adding grantRole.
    const names = ourFragments.map((f) => `${f.type} ${f.name}`).sort();
    expect(names).toEqual(
      [
        'function registerConsignment',
        'function recordHandoff',
        'function recordPurchase',
        'function getConsignment',
        'function RECORDER_ROLE',
        'function hasRole',
        'event ConsignmentRegistered',
        'event HandoffRecorded',
        'event PurchaseRecorded',
        'error AccessControlUnauthorizedAccount',
        'error InvalidInput',
        'error InvalidStage',
        'error ConsignmentAlreadyExists',
      ].sort(),
    );
  });

  it('leaves out every role-changing function', () => {
    for (const name of ['grantRole', 'revokeRole', 'renounceRole']) {
      expect(ours.getFunction(name)).toBeNull();
    }
  });

  describe.each(ourFragments.map((f) => [`${f.type} ${f.name}`, f]))('%s', (_label, fragment) => {
    it('exists in the deployed contract', () => {
      expect(deployedFragment(fragment)).toBeDefined();
    });

    it('has the same full signature: types, names, indexed flags, outputs, mutability', () => {
      // format('full') includes everything ethers knows about the fragment, so this one
      // comparison covers parameter types and order, tuple field names, which event fields
      // are indexed, return types, and view versus state-changing.
      expect(fragment.format('full')).toBe(deployedFragment(fragment).format('full'));
    });

    it('has the same selector or topic hash', () => {
      // Checked separately because the selector is what actually goes on the wire: the first
      // 4 bytes of calldata or revert data, or the first topic of a log.
      const theirs = deployedFragment(fragment);
      if (fragment.type === 'event') {
        expect(fragment.topicHash).toBe(theirs.topicHash);
      } else {
        expect(fragment.selector).toBe(theirs.selector);
      }
    });
  });

  it('marks the three writes as state-changing and not payable', () => {
    // A view by mistake would make ethers call instead of send: no transaction, no anchor.
    // Payable by mistake would let a bug attach ETH to every write.
    for (const name of ['registerConsignment', 'recordHandoff', 'recordPurchase']) {
      expect(ours.getFunction(name).stateMutability).toBe('nonpayable');
    }
  });
});

describe('deployment constants', () => {
  it('EXPECTED_CODE_HASH is keccak256 of the artifact deployedBytecode', () => {
    expect(EXPECTED_CODE_HASH).toMatch(/^0x[0-9a-f]{64}$/);
    expect(keccak256(artifact.deployedBytecode)).toBe(EXPECTED_CODE_HASH);
  });

  it('the bytecode can be compared byte for byte (no immutables, no linked libraries)', () => {
    // Immutables and library addresses are filled in at deployment, so with either one the
    // code on-chain would differ from the artifact and the hash check could never pass.
    expect(artifact.immutableReferences ?? {}).toEqual({});
    expect(artifact.deployedLinkReferences ?? {}).toEqual({});
  });

  it('DEPLOY_BLOCK is the block of the deployment receipt in the Ignition journal', () => {
    // journal.jsonl is one JSON object per line; the deployment's receipt is the entry for
    // this future that carries a contractAddress.
    const entries = readDeploymentFile('journal.jsonl')
      .split('\n')
      .filter((line) => line.trim() !== '')
      .map((line) => JSON.parse(line));
    const deployment = entries.find((e) => e.futureId === FUTURE_ID && e.receipt?.contractAddress);

    expect(deployment).toBeDefined();
    expect(deployment.receipt.blockNumber).toBe(DEPLOY_BLOCK);
  });

  it('SEPOLIA_CHAIN_ID is 11155111 as a bigint, as ethers reports chain ids', () => {
    expect(SEPOLIA_CHAIN_ID).toBe(11155111n);
  });
});
