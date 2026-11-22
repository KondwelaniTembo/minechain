import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { CHECK_RESULTS, checkStep, evidenceMismatches, missingReceiptIsMismatch, receiptPruned } from '../src/services/chainCheck.js';
import { anchorHash } from '../src/services/signatureService.js';
import { ChainClientError } from '../src/chain/rpc.js';
import { classifyChainError } from '../src/chain/chainErrors.js';
import { DEPLOY_BLOCK } from '../src/chain/mineChainAbi.js';
import { createFakeChainReader } from './fakes/fakeChainReader.js';
import { FAKE_CONTRACT_ADDRESS } from './fakes/fakeChainClient.js';

// The fixed vectors (never regenerated): real payloads, keys and signatures, with the
// anchor hash each one must give.
const VECTORS = JSON.parse(readFileSync(new URL('../../docs/signing-vectors.json', import.meta.url), 'utf8'));
const vector = (name) => VECTORS.positive.find((v) => v.name === name);

const CHAIN_ID = Buffer.from(`${'00'.repeat(16)}6f1d2c3a00004000800000000000a101`, 'hex');
const ACTOR_REF = Buffer.alloc(32, 0xaa);
const TX_HASH = Buffer.alloc(32, 0xcc);
const TX_HASH_HEX = `0x${TX_HASH.toString('hex')}`;
const BLOCK = DEPLOY_BLOCK + 50;
const CONFIRMATIONS = 2;
const OPTIONS = { confirmations: CONFIRMATIONS };

const EVENTS = Object.freeze({
  registration: { name: 'ConsignmentRegistered', actorArg: 'minerRef' },
  handoff: { name: 'HandoffRecorded', actorArg: 'transporterRef' },
  purchase: { name: 'PurchaseRecorded', actorArg: 'buyerRef' },
});

const hex = (bytes) => `0x${Buffer.from(bytes).toString('hex')}`;

// A confirmed row as B2.4's query will return it from pg: bigint and numeric as text,
// timestamptz as a Date, bytea as Buffers.
function rowFor(name, overrides = {}) {
  const v = vector(name);
  const f = v.fields;
  return {
    type: f.type,
    idempotency_key: f.stepId,
    actor_id: f.actorId,
    qr_code: f.qrCode,
    mineral_type: f.mineral ?? 'gold',
    weight_mg: f.weightMg,
    latitude: f.latitude,
    longitude: f.longitude,
    captured_at: new Date(f.capturedAt),
    signed_payload: v.payload,
    signature: Buffer.from(v.signature, 'base64'),
    signer_public_key: Buffer.from(v.publicKey, 'base64'),
    data_hash: Buffer.from(v.anchorHash, 'hex'),
    hash_version: 1,
    anchor_status: 'confirmed',
    chain_tx_hash: TX_HASH,
    block_number: String(BLOCK),
    chain_id: CHAIN_ID,
    actor_ref: ACTOR_REF,
    ...overrides,
  };
}

// The event the recorder emitted for the vector's step, as the reader decodes it.
function eventFor(name, overrides = {}) {
  const v = vector(name);
  const { name: eventName, actorArg } = EVENTS[v.fields.type];
  const { args: argOverrides = {}, ...rest } = overrides;
  return {
    address: FAKE_CONTRACT_ADDRESS,
    name: eventName,
    args: {
      id: hex(CHAIN_ID),
      [actorArg]: hex(ACTOR_REF),
      weightMilligrams: BigInt(v.fields.weightMg),
      dataHash: `0x${v.anchorHash}`,
      timestamp: 1_762_600_000n,
      ...argOverrides,
    },
    blockNumber: BLOCK,
    transactionHash: TX_HASH_HEX,
    logIndex: 0,
    ...rest,
  };
}

function receiptFor(name, overrides = {}) {
  return {
    hash: TX_HASH_HEX,
    status: 1,
    blockNumber: BLOCK,
    blockHash: `0x${'bb'.repeat(32)}`,
    gasUsed: 59_299n,
    events: [eventFor(name)],
    ...overrides,
  };
}

// A fake reader holding the receipt, with the node well past the block.
function readerWith(receipt, { latest = BLOCK + 10 } = {}) {
  const { reader, control } = createFakeChainReader();
  if (receipt) control.setReceipt(TX_HASH_HEX, receipt);
  control.setBlockNumber(latest);
  return { reader, control };
}

// A reader that fails the test if it is asked anything.
const untouchable = Object.freeze({
  contractAddress: FAKE_CONTRACT_ADDRESS,
  getReceipt: () => {
    throw new Error('no chain call was expected');
  },
  getBlockNumber: () => {
    throw new Error('no chain call was expected');
  },
  getTransaction: () => {
    throw new Error('no chain call was expected');
  },
  close() {},
});

const rpcDown = () => new ChainClientError(classifyChainError({ code: 'ECONNREFUSED' }), 'primary');

const mismatchOf = (fields, extra = {}) => ({ result: 'mismatch', fields, ...extra });

describe('checkStep: match', () => {
  it.each(['registration', 'handoff', 'purchase'])('a genuine anchored %s matches', async (name) => {
    const { reader, control } = readerWith(receiptFor(name));

    await expect(checkStep(reader, rowFor(name), OPTIONS)).resolves.toEqual({ result: 'match', fields: [] });

    // One receipt, by the stored hash; no block number needed when the receipt is there.
    expect(control.calls).toEqual([{ method: 'getReceipt', hash: TX_HASH_HEX }]);
  });

  it('matches when the step event is not the first in the receipt', async () => {
    const other = eventFor('registration', { address: `0x${'12'.repeat(20)}` });
    const { reader } = readerWith(receiptFor('registration', { events: [other, eventFor('registration')] }));

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).resolves.toMatchObject({ result: 'match' });
  });

  it('ignores the consignment mineral on a handoff, whose payload does not sign it', async () => {
    const { reader } = readerWith(receiptFor('handoff'));

    await expect(checkStep(reader, rowFor('handoff', { mineral_type: 'copper' }), OPTIONS)).resolves.toMatchObject({ result: 'match' });
  });

  it('returns a frozen result', async () => {
    const { reader } = readerWith(receiptFor('registration'));

    const answer = await checkStep(reader, rowFor('registration'), OPTIONS);

    expect(Object.isFrozen(answer)).toBe(true);
    expect(Object.isFrozen(answer.fields)).toBe(true);
  });
});

describe('checkStep: the stored evidence (steps 1 and 2), with no chain call', () => {
  it('one changed byte in the payload, still well formed: signature, the column and the hash', async () => {
    const row = rowFor('registration');
    row.signed_payload = row.signed_payload.replace('weight_mg=1500000', 'weight_mg=1600000');

    await expect(checkStep(untouchable, row, OPTIONS)).resolves.toEqual(mismatchOf(['signature', 'weight_mg', 'data_hash']));
  });

  it('one changed byte that breaks the payload grammar: signature, signed_payload and the hash', async () => {
    const row = rowFor('registration');
    row.signed_payload = row.signed_payload.replace('mineral=gold', 'mineral=gole');

    await expect(checkStep(untouchable, row, OPTIONS)).resolves.toEqual(mismatchOf(['signature', 'signed_payload', 'data_hash']));
  });

  it('one changed byte in the key: no longer a valid P-256 key', async () => {
    const row = rowFor('registration');
    row.signer_public_key = Buffer.from(row.signer_public_key);
    row.signer_public_key[0] ^= 0x01;

    await expect(checkStep(untouchable, row, OPTIONS)).resolves.toEqual(mismatchOf(['signer_public_key']));
  });

  it('one changed byte in the signature: it no longer verifies, and the recomputed hash differs', async () => {
    const row = rowFor('registration');
    row.signature = Buffer.from(row.signature);
    row.signature[row.signature.length - 1] ^= 0x01;

    await expect(checkStep(untouchable, row, OPTIONS)).resolves.toEqual(mismatchOf(['signature', 'data_hash']));
  });

  it('a signature cut too short to be DER', async () => {
    const row = rowFor('registration', { signature: Buffer.alloc(4, 0x30) });

    await expect(checkStep(untouchable, row, OPTIONS)).resolves.toEqual(mismatchOf(['signature']));
  });

  it('the data_hash column itself edited', async () => {
    const row = rowFor('registration', { data_hash: Buffer.alloc(32, 0xdd) });

    await expect(checkStep(untouchable, row, OPTIONS)).resolves.toEqual(mismatchOf(['data_hash']));
  });

  it.each([
    ['weight_mg', '1400000'],
    ['latitude', '-15.000000'],
    ['longitude', '28.000000'],
    ['captured_at', new Date('2026-11-10T08:00:00.001Z')],
    ['actor_id', '3f2b6c1e-0000-4000-8000-000000000999'],
    ['qr_code', 'MC-DEMO-000002'],
    ['mineral_type', 'copper'],
    ['idempotency_key', '6f1d2c3a-0000-4000-8000-000000000999'],
    ['type', 'handoff'],
  ])('an altered %s column is named, alone', async (column, value) => {
    const row = rowFor('registration', { [column]: value });

    await expect(checkStep(untouchable, row, OPTIONS)).resolves.toEqual(mismatchOf([column]));
  });

  it('a coordinate given as a JavaScript number never counts as equal', async () => {
    const row = rowFor('registration', { latitude: -15.419012 });

    await expect(checkStep(untouchable, row, OPTIONS)).resolves.toEqual(mismatchOf(['latitude']));
  });

  it('hash version 2 is a mismatch on hash_version, and nothing else is compared', async () => {
    const row = rowFor('registration', { hash_version: 2 });

    await expect(checkStep(untouchable, row, OPTIONS)).resolves.toEqual(mismatchOf(['hash_version']));
  });

  it('is a mismatch even with no reader, or with the RPC down: the evidence alone shows it', async () => {
    const row = rowFor('registration', { weight_mg: '1400000' });
    const { reader, control } = readerWith(receiptFor('registration'));
    control.failRpc();

    await expect(checkStep(null, row, OPTIONS)).resolves.toEqual(mismatchOf(['weight_mg']));
    await expect(checkStep(reader, row, OPTIONS)).resolves.toEqual(mismatchOf(['weight_mg']));
    expect(control.calls).toEqual([]);
  });

  describe('a consistent forgery after sync: payload, column and data_hash edited together', () => {
    // The attacker changes the weight in the payload and the column, then recomputes
    // data_hash with the public anchor hash function. Only the signature gives it away.
    function forgedRow() {
      const row = rowFor('registration');
      row.signed_payload = row.signed_payload.replace('weight_mg=1500000', 'weight_mg=1600000');
      row.weight_mg = '1600000';
      row.data_hash = anchorHash({ payload: row.signed_payload, signature: row.signature, publicKey: row.signer_public_key });
      return row;
    }

    it('every other local comparison agrees, so the signature is all that is named', () => {
      expect(evidenceMismatches(forgedRow()).fields).toEqual(['signature']);
    });

    it('(a) with no reader: mismatch on signature', async () => {
      await expect(checkStep(null, forgedRow(), OPTIONS)).resolves.toEqual(mismatchOf(['signature']));
    });

    it('(b) with the RPC down: mismatch, not chain_unavailable, and no chain call', async () => {
      const { reader, control } = readerWith(receiptFor('registration'));
      control.failRpc();

      await expect(checkStep(reader, forgedRow(), OPTIONS)).resolves.toEqual(mismatchOf(['signature']));
      expect(control.calls).toEqual([]);
    });

    it('(c) with a working reader: mismatch, decided before any chain call', async () => {
      const { reader, control } = readerWith(receiptFor('registration'));

      await expect(checkStep(reader, forgedRow(), OPTIONS)).resolves.toEqual(mismatchOf(['signature']));
      expect(control.calls).toEqual([]);
    });
  });

  it('names fields only, never their values', async () => {
    const row = rowFor('registration', { weight_mg: '1400000', latitude: '-15.000000' });

    const text = JSON.stringify(await checkStep(untouchable, row, OPTIONS));

    for (const value of ['1400000', '1500000', '-15.000000', '-15.419012', 'MC-DEMO-000001', row.actor_id]) {
      expect(text).not.toContain(value);
    }
  });

  it('evidenceMismatches gives the recomputed hash for a genuine row', () => {
    const { fields, recomputedHash } = evidenceMismatches(rowFor('handoff'));

    expect(fields).toEqual([]);
    expect(recomputedHash.toString('hex')).toBe(vector('handoff').anchorHash);
  });
});

describe('checkStep: the receipt (step 3)', () => {
  it.each([
    ['name', { name: 'PurchaseRecorded' }, 'event.name'],
    ['contract address', { address: `0x${'12'.repeat(20)}` }, 'event.address'],
    ['consignment id', { args: { id: `0x${'22'.repeat(32)}` } }, 'event.id'],
    ['actor reference', { args: { minerRef: `0x${'bb'.repeat(32)}` } }, 'event.minerRef'],
    ['weight', { args: { weightMilligrams: 1_400_000n } }, 'event.weightMilligrams'],
    ['data hash', { args: { dataHash: `0x${'dd'.repeat(32)}` } }, 'event.dataHash'],
  ])('a wrong event %s is named', async (_label, overrides, field) => {
    const { reader } = readerWith(receiptFor('registration', { events: [eventFor('registration', overrides)] }));

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).resolves.toEqual(mismatchOf([field]));
  });

  it('compares the event with the RECOMPUTED hash: an event and column edited to agree still mismatch', async () => {
    // Someone rewrote data_hash in the row to a value they also "found" on-chain; the
    // evidence still hashes to the original, so step 2 catches the column first.
    const forged = `0x${'dd'.repeat(32)}`;
    const row = rowFor('registration', { data_hash: Buffer.from(forged.slice(2), 'hex') });
    const { reader } = readerWith(receiptFor('registration', { events: [eventFor('registration', { args: { dataHash: forged } })] }));

    await expect(checkStep(reader, row, OPTIONS)).resolves.toEqual(mismatchOf(['data_hash']));
  });

  it('a receipt with no MineChain event names every event field', async () => {
    const { reader } = readerWith(receiptFor('handoff', { events: [] }));

    await expect(checkStep(reader, rowFor('handoff'), OPTIONS)).resolves.toEqual(
      mismatchOf(['event.address', 'event.name', 'event.id', 'event.transporterRef', 'event.weightMilligrams', 'event.dataHash']),
    );
  });

  it('a reverted receipt', async () => {
    const { reader } = readerWith(receiptFor('registration', { status: 0 }));

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).resolves.toEqual(mismatchOf(['receipt.status']));
  });

  it('a receipt in another block than the stored block_number', async () => {
    const { reader } = readerWith(receiptFor('registration', { blockNumber: BLOCK + 1 }));

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).resolves.toEqual(mismatchOf(['receipt.blockNumber']));
  });
});

describe('checkStep: no receipt (step 4)', () => {
  // Changed by the verification fix (22 Nov): the node is now also asked for the
  // transaction before a missing receipt is called a mismatch, so a third call is expected.
  it('node at block_number + confirmations, transaction unknown too: mismatch TX_NOT_FOUND', async () => {
    const { reader, control } = readerWith(null, { latest: BLOCK + CONFIRMATIONS });

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).resolves.toEqual(
      mismatchOf(['chain_tx_hash'], { reason: 'TX_NOT_FOUND' }),
    );
    expect(control.calls.map((c) => c.method)).toEqual(['getReceipt', 'getBlockNumber', 'getTransaction']);
    expect(control.calls.at(-1).hash).toBe(TX_HASH_HEX);
  });

  it('node one block short of that: chain_unavailable (it is behind), and the transaction is not asked for', async () => {
    const { reader, control } = readerWith(null, { latest: BLOCK + CONFIRMATIONS - 1 });

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).resolves.toEqual({ result: 'chain_unavailable', fields: [] });
    expect(control.calls.map((c) => c.method)).toEqual(['getReceipt', 'getBlockNumber']);
  });

  it('a receipt is found: the transaction is not asked for', async () => {
    const { reader, control } = readerWith(receiptFor('registration'));

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).resolves.toEqual({ result: 'match', fields: [] });
    expect(control.calls.map((c) => c.method)).toEqual(['getReceipt']);
  });

  // The 0008 case from the Reports T5 phone check: the node pruned the receipt, long past
  // the block, but still holds the transaction where the row says it was mined.
  it.each(['registration', 'handoff', 'purchase'])(
    'a %s whose receipt was pruned (its transaction still in the stored block, sent to MineChain): chain_unavailable',
    async (name) => {
      const { reader, control } = readerWith(null, { latest: BLOCK + 20_000 });
      control.setTransaction(TX_HASH_HEX, { hash: TX_HASH_HEX, blockNumber: BLOCK, to: FAKE_CONTRACT_ADDRESS });

      await expect(checkStep(reader, rowFor(name), OPTIONS)).resolves.toEqual({ result: 'chain_unavailable', fields: [] });
    },
  );

  it('compares the contract address without regard to letter case', async () => {
    const { reader, control } = readerWith(null);
    control.setTransaction(TX_HASH_HEX, { hash: TX_HASH_HEX, blockNumber: BLOCK, to: FAKE_CONTRACT_ADDRESS.toLowerCase() });

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).resolves.toMatchObject({ result: 'chain_unavailable' });
  });

  it.each([
    ['in another block', { blockNumber: BLOCK + 1 }],
    ['still pending (no block)', { blockNumber: null }],
    ['sent to another address', { to: `0x${'12'.repeat(20)}` }],
    ['a contract creation (no recipient)', { to: null }],
  ])('a transaction found but %s cannot be this anchoring: mismatch TX_NOT_FOUND', async (_label, overrides) => {
    const { reader, control } = readerWith(null);
    control.setTransaction(TX_HASH_HEX, { hash: TX_HASH_HEX, blockNumber: BLOCK, to: FAKE_CONTRACT_ADDRESS, ...overrides });

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).resolves.toEqual(
      mismatchOf(['chain_tx_hash'], { reason: 'TX_NOT_FOUND' }),
    );
  });

  it('the transaction cannot be read: chain_unavailable, never a mismatch', async () => {
    const reader = {
      contractAddress: FAKE_CONTRACT_ADDRESS,
      getReceipt: async () => null,
      getBlockNumber: async () => BLOCK + 100,
      getTransaction: async () => {
        throw rpcDown();
      },
    };

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).resolves.toEqual({ result: 'chain_unavailable', fields: [] });
  });

  it('receiptPruned compares the block exactly, with block_number as pg text', () => {
    const tx = { hash: TX_HASH_HEX, blockNumber: 100, to: FAKE_CONTRACT_ADDRESS };

    expect(receiptPruned(tx, '100', FAKE_CONTRACT_ADDRESS)).toBe(true);
    expect(receiptPruned(tx, '101', FAKE_CONTRACT_ADDRESS)).toBe(false);
    expect(receiptPruned(null, '100', FAKE_CONTRACT_ADDRESS)).toBe(false);
  });

  it('the block number cannot be read: chain_unavailable', async () => {
    const reader = {
      contractAddress: FAKE_CONTRACT_ADDRESS,
      getReceipt: async () => null,
      getBlockNumber: async () => {
        throw rpcDown();
      },
    };

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).resolves.toMatchObject({ result: 'chain_unavailable' });
  });

  it('missingReceiptIsMismatch compares exactly, with block_number as pg text', () => {
    expect(missingReceiptIsMismatch(102, '100', 2)).toBe(true);
    expect(missingReceiptIsMismatch(101, '100', 2)).toBe(false);
  });
});

describe('checkStep: chain unavailable (step 5), never a mismatch', () => {
  it('the RPC down', async () => {
    const { reader, control } = readerWith(receiptFor('registration'));
    control.failRpc();

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).resolves.toEqual({ result: 'chain_unavailable', fields: [] });
  });

  it.each(['WRONG_CHAIN', 'NO_CONTRACT_CODE', 'WRONG_CONTRACT_CODE'])('the reader refusing with %s', async (code) => {
    const { reader, control } = readerWith(receiptFor('registration'));
    control.refuse(code);

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).resolves.toMatchObject({ result: 'chain_unavailable' });
  });

  it('no reader configured', async () => {
    await expect(checkStep(null, rowFor('registration'), OPTIONS)).resolves.toEqual({ result: 'chain_unavailable', fields: [] });
  });

  it('an error that is not a chain error is a bug, and is not hidden as unavailable', async () => {
    const reader = {
      contractAddress: FAKE_CONTRACT_ADDRESS,
      getReceipt: async () => {
        throw new Error('a programming fault');
      },
      getBlockNumber: async () => 0,
    };

    await expect(checkStep(reader, rowFor('registration'), OPTIONS)).rejects.toThrow('a programming fault');
  });
});

describe('checkStep: not confirmed', () => {
  it.each(['pending', 'submitted', 'failed'])('anchor_status %s: not_anchored_yet, no chain call', async (status) => {
    // Even with evidence that would not match: there is nothing on-chain to compare yet.
    const row = rowFor('registration', { anchor_status: status, chain_tx_hash: null, block_number: null, weight_mg: '1400000' });

    await expect(checkStep(untouchable, row, OPTIONS)).resolves.toEqual({ result: 'not_anchored_yet', fields: [] });
  });

  it('the result names are the four of the plan', () => {
    expect(Object.values(CHECK_RESULTS).sort()).toEqual(['chain_unavailable', 'match', 'mismatch', 'not_anchored_yet']);
  });
});

describe('checkStep: arguments', () => {
  it.each([undefined, 0, 1.5, '2'])('refuses confirmations %s', async (confirmations) => {
    await expect(checkStep(null, rowFor('registration'), { confirmations })).rejects.toThrow(TypeError);
  });
});
