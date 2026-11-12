import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { Interface } from 'ethers';
import {
  buildAnchorCall,
  receiptEventMismatches,
  AnchorCallError,
  ANCHOR_CALL_ERROR_CODES,
} from '../src/services/anchorCall.js';
import { MINECHAIN_ABI } from '../src/chain/mineChainAbi.js';

const abi = new Interface(MINECHAIN_ABI);
const CONTRACT_ADDRESS = '0x6419cB5268706E2aA4713AB3bCFc336248Ed158a';

// Distinct filler bytes, so a test can tell which argument ended up where.
const bytes = (fill) => Buffer.alloc(32, fill);
const hex = (fill) => `0x${bytes(fill).toString('hex')}`;

// The shape of a consignments.chain_id: 16 zero bytes, then the uuid's 16 bytes.
const CHAIN_ID = Buffer.concat([Buffer.alloc(16), Buffer.from('6f1d2c3a00004000800000000000a101', 'hex')]);

const step = (overrides = {}) => ({
  type: 'registration',
  chain_id: CHAIN_ID,
  actor_ref: bytes(0xaa),
  weight_mg: '1500000',
  data_hash: bytes(0xdd),
  ...overrides,
});

function expectAnchorCallError(fn, code) {
  expect(fn).toThrow(AnchorCallError);
  expect(fn).toThrow(expect.objectContaining({ code }));
}

describe('buildAnchorCall', () => {
  it.each([
    ['registration', 'registerConsignment'],
    ['handoff', 'recordHandoff'],
    ['purchase', 'recordPurchase'],
  ])('maps a %s step to %s(id, actorRef, weightMilligrams, dataHash)', (type, functionName) => {
    const call = buildAnchorCall(step({ type }));

    expect(call.functionName).toBe(functionName);
    expect(call.args).toEqual([`0x${CHAIN_ID.toString('hex')}`, hex(0xaa), 1_500_000n, hex(0xdd)]);
  });

  it.each(['registration', 'handoff', 'purchase'])(
    'the %s arguments encode against the ABI and decode back in the same order',
    (type) => {
      // Proves order and types together: swapping actorRef and dataHash would still encode
      // (both bytes32), so the decoded values are compared by name as well.
      const { functionName, args } = buildAnchorCall(step({ type }));
      const decoded = abi.decodeFunctionData(functionName, abi.encodeFunctionData(functionName, args));

      expect(decoded.id).toBe(args[0]);
      expect(decoded[1]).toBe(hex(0xaa));
      expect(decoded.weightMilligrams).toBe(1_500_000n);
      expect(decoded.dataHash).toBe(hex(0xdd));
    },
  );

  it('returns a frozen call, so the worker cannot change it between check and send', () => {
    const call = buildAnchorCall(step());

    expect(Object.isFrozen(call)).toBe(true);
    expect(Object.isFrozen(call.args)).toBe(true);
  });

  it('maps the registration anchor hash from docs/signing-vectors.json exactly', () => {
    const vectors = JSON.parse(readFileSync(new URL('../../docs/signing-vectors.json', import.meta.url), 'utf8'));
    const vector = vectors.positive.find((v) => v.name === 'registration');

    const { args } = buildAnchorCall(step({ data_hash: Buffer.from(vector.anchorHash, 'hex') }));

    expect(args[3]).toBe(`0x${vector.anchorHash}`);
  });

  it.each(['export', 'Registration', '', 'constructor', '__proto__', 'toString', undefined, null, 1])(
    'refuses step type %s',
    (type) => {
      expectAnchorCallError(() => buildAnchorCall(step({ type })), ANCHOR_CALL_ERROR_CODES.STEP_TYPE_UNKNOWN);
    },
  );

  describe('weight', () => {
    it.each([
      ['1', 1n],
      // The largest PostgreSQL bigint, kept exact (it is far beyond 2^53).
      ['9223372036854775807', 9_223_372_036_854_775_807n],
      // The largest uint64.
      ['18446744073709551615', 18_446_744_073_709_551_615n],
    ])('turns "%s" into exactly %sn', (text, expected) => {
      expect(buildAnchorCall(step({ weight_mg: text })).args[2]).toBe(expected);
    });

    it('does not round a value that a float would', () => {
      // As a JavaScript number this becomes 9007199254740992.
      expect(buildAnchorCall(step({ weight_mg: '9007199254740993' })).args[2]).toBe(9_007_199_254_740_993n);
    });

    it.each([
      ['1.5'],
      ['0'],
      ['-1'],
      ['1e3'],
      ['01'],
      [''],
      [' 1'],
      ['1 '],
      ['0x10'],
      ['18446744073709551616'], // 2^64, one above uint64
    ])('refuses "%s"', (text) => {
      expectAnchorCallError(() => buildAnchorCall(step({ weight_mg: text })), ANCHOR_CALL_ERROR_CODES.WEIGHT_INVALID);
    });

    it.each([
      ['a JavaScript number', 1500000],
      ['a bigint', 1500000n],
      ['null', null],
      ['undefined', undefined],
    ])('refuses %s, because pg always returns bigint columns as text', (_label, value) => {
      expectAnchorCallError(() => buildAnchorCall(step({ weight_mg: value })), ANCHOR_CALL_ERROR_CODES.WEIGHT_INVALID);
    });
  });

  describe('bytes32 fields', () => {
    describe.each(['chain_id', 'actor_ref', 'data_hash'])('%s', (field) => {
      it.each([
        ['31 bytes', Buffer.alloc(31, 1)],
        ['33 bytes', Buffer.alloc(33, 1)],
        ['0 bytes', Buffer.alloc(0)],
        ['a hex string', hex(0x11)],
        ['null', null],
        ['undefined', undefined],
      ])('refuses %s', (_label, value) => {
        expectAnchorCallError(() => buildAnchorCall(step({ [field]: value })), ANCHOR_CALL_ERROR_CODES.BYTES32_INVALID);
      });

      it('refuses 32 zero bytes, which the contract would revert on', () => {
        expectAnchorCallError(
          () => buildAnchorCall(step({ [field]: Buffer.alloc(32) })),
          ANCHOR_CALL_ERROR_CODES.BYTES32_INVALID,
        );
      });

      it('names the field in the error', () => {
        expect(() => buildAnchorCall(step({ [field]: Buffer.alloc(31, 1) }))).toThrow(new RegExp(field));
      });
    });

    it('accepts a plain Uint8Array as well as a Buffer', () => {
      const { args } = buildAnchorCall(step({ actor_ref: new Uint8Array(32).fill(0xaa) }));

      expect(args[1]).toBe(hex(0xaa));
    });
  });
});

describe('receiptEventMismatches', () => {
  const EVENTS = { registration: 'ConsignmentRegistered', handoff: 'HandoffRecorded', purchase: 'PurchaseRecorded' };

  // A real round trip: encode the event as the contract would log it, then decode it the way
  // the chain client will, with parseLog.
  function loggedEvent(type, { eventName = EVENTS[type], address = CONTRACT_ADDRESS, values } = {}) {
    const [id, actorRef, weight, dataHash] = buildAnchorCall(step({ type })).args;
    const fragment = abi.getEvent(eventName);
    const log = abi.encodeEventLog(fragment, values ?? [id, actorRef, weight, dataHash, 1_762_600_000n]);
    const parsed = abi.parseLog(log);
    return { address, name: parsed.name, args: parsed.args };
  }

  it.each(['registration', 'handoff', 'purchase'])('finds no mismatch for the %s event of the same step', (type) => {
    expect(receiptEventMismatches(loggedEvent(type), step({ type }), CONTRACT_ADDRESS)).toEqual([]);
  });

  it('compares the contract address ignoring checksum case', () => {
    const event = loggedEvent('registration', { address: CONTRACT_ADDRESS.toLowerCase() });

    expect(receiptEventMismatches(event, step(), CONTRACT_ADDRESS)).toEqual([]);
  });

  it('reports an event from another contract', () => {
    const event = loggedEvent('registration', { address: `0x${'12'.repeat(20)}` });

    expect(receiptEventMismatches(event, step(), CONTRACT_ADDRESS)).toEqual(['address']);
  });

  it('reports the wrong event for the step type', () => {
    // Same values and argument shape, so the name is the real difference. The actor field
    // is reported too, because ConsignmentRegistered calls it minerRef, not transporterRef.
    const event = loggedEvent('handoff', { eventName: 'ConsignmentRegistered' });

    expect(receiptEventMismatches(event, step({ type: 'handoff' }), CONTRACT_ADDRESS)).toEqual([
      'name',
      'transporterRef',
    ]);
  });

  it.each([
    ['id', 0, hex(0x01), 'id'],
    ['actor reference', 1, hex(0x02), 'transporterRef'],
    ['weight', 2, 1_500_001n, 'weightMilligrams'],
    ['data hash', 3, hex(0x03), 'dataHash'],
  ])('reports a different %s by its event field name', (_label, index, value, field) => {
    const values = [...buildAnchorCall(step({ type: 'handoff' })).args, 1_762_600_000n];
    values[index] = value;

    const event = loggedEvent('handoff', { values });

    expect(receiptEventMismatches(event, step({ type: 'handoff' }), CONTRACT_ADDRESS)).toEqual([field]);
  });

  it('reports a weight decoded as a number instead of a bigint', () => {
    const event = loggedEvent('registration');
    const args = { ...event.args.toObject(), weightMilligrams: 1500000 };

    expect(receiptEventMismatches({ ...event, args }, step(), CONTRACT_ADDRESS)).toEqual(['weightMilligrams']);
  });

  it('reports every field for a missing event, without throwing', () => {
    expect(receiptEventMismatches(undefined, step(), CONTRACT_ADDRESS)).toEqual([
      'address',
      'name',
      'id',
      'minerRef',
      'weightMilligrams',
      'dataHash',
    ]);
  });
});
