import { describe, it, expect } from 'vitest';
import { canSeeConsignment, discloseConsignment } from '../src/services/consignmentDisclosure.js';

// Fake people and records only. Every secret-looking value below is unique text, so a deep
// scan of a body can tell exactly where it leaked from.

const IDS = Object.freeze({
  miner: '3f2b6c1e-0000-4000-8000-0000000000a1',
  transporter: '3f2b6c1e-0000-4000-8000-0000000000b1',
  otherTransporter: '3f2b6c1e-0000-4000-8000-0000000000b2',
  buyer: '3f2b6c1e-0000-4000-8000-0000000000c1',
  otherBuyer: '3f2b6c1e-0000-4000-8000-0000000000c2',
  officer: '3f2b6c1e-0000-4000-8000-0000000000d1',
});

const VIEWERS = Object.freeze({
  // Extra fields as requireAuth might add; none may reach the body.
  transporter: { id: IDS.transporter, role: 'transporter', username: 'viewer-transporter', fullName: 'Viewer Full Name' },
  buyer: { id: IDS.buyer, role: 'buyer', username: 'viewer-buyer' },
  otherBuyer: { id: IDS.otherBuyer, role: 'buyer' },
  officer: { id: IDS.officer, role: 'officer' },
});

const CONSIGNMENT_ID = '9a000000-0000-4000-8000-000000000001';

function consignment(stage) {
  return {
    id: CONSIGNMENT_ID,
    qr_code: 'MC-DEMO-000001',
    mineral_type: 'gold',
    stage,
    // Columns the query might also return one day.
    miner_id: IDS.miner,
    chain_id: Buffer.alloc(32, 0x11),
    secret_column: 'LEAK-CONSIGNMENT-COLUMN',
  };
}

const payload = (type, weight, lat, lon) =>
  `minechain-step/1/${type}\nweight_mg=${weight}\nlatitude=${lat}\nlongitude=${lon}\n`;

// One step per interesting case. The values in `hidden` are each unique to one field.
function makeStep(n, { type, actor, role, username, review, anchor = 'confirmed', weight, lat, lon, zone = 'Campus Zone' }) {
  return {
    id: `7b000000-0000-4000-8000-00000000000${n}`,
    type,
    actor_id: IDS[actor],
    actor_role: role,
    actor_username: username,
    review_status: review,
    anchor_status: anchor,
    // A submitted step already has its hash (sent, not yet mined); a pending one has none.
    chain_tx_hash: ['submitted', 'confirmed'].includes(anchor) ? Buffer.alloc(32, 0xc0 + n) : null,
    block_number: anchor === 'confirmed' ? String(12047650 + n) : null,
    weight_mg: weight,
    latitude: lat,
    longitude: lon,
    zone_name: zone,
    captured_at: new Date(`2026-11-1${n}T08:00:00.000Z`),
    received_at: new Date(`2026-11-1${n}T08:05:00.000Z`),
    signed_payload: payload(type, weight, lat, lon),
    signature: Buffer.from(`signature-bytes-${n}`),
    signer_public_key: Buffer.from(`public-key-bytes-${n}`),
    // Never to be shown, whatever the role.
    full_name: `Full Name ${n}`,
    licence_number: `LIC-SECRET-${n}`,
    actor_ref: Buffer.alloc(32, 0xa0 + n),
    anchor_error: `ANCHOR-ERROR-${n}`,
    anchor_nonce: 9000 + n,
    data_hash: Buffer.alloc(32, 0xe0 + n),
    secret_column: `LEAK-STEP-COLUMN-${n}`,
  };
}

const REGISTRATION = makeStep(1, { type: 'registration', actor: 'miner', role: 'miner', username: 'miner-user', review: 'passed', weight: '1500000', lat: '-15.419012', lon: '28.288105' });
const HANDOFF = makeStep(2, { type: 'handoff', actor: 'transporter', role: 'transporter', username: 'transporter-user', review: 'cleared', weight: '1495000', lat: '-15.418900', lon: '28.288700' });
const FLAGGED = makeStep(3, { type: 'handoff', actor: 'otherTransporter', role: 'transporter', username: 'flagged-user', review: 'flagged', anchor: 'pending', weight: '1200000', lat: '-15.410001', lon: '28.280001', zone: null });
const REJECTED = makeStep(4, { type: 'handoff', actor: 'otherTransporter', role: 'transporter', username: 'rejected-user', review: 'rejected', anchor: 'pending', weight: '1100000', lat: '-15.410002', lon: '28.280002' });
const PURCHASE = makeStep(5, { type: 'purchase', actor: 'buyer', role: 'buyer', username: 'buyer-user', review: 'passed', anchor: 'submitted', weight: '1494500', lat: '-15.419300', lon: '28.287800' });

const STEPS_BY_STAGE = Object.freeze({
  registered: [REGISTRATION],
  in_transit: [REGISTRATION, HANDOFF, FLAGGED, REJECTED],
  purchased: [REGISTRATION, HANDOFF, FLAGGED, REJECTED, PURCHASE],
});

const MISMATCH = Object.freeze({ result: 'mismatch', fields: ['weight_mg', 'data_hash'], reason: 'SOME_REASON' });

function checksFor(steps) {
  return new Map(
    steps.map((s) => [
      s.id,
      s.id === REGISTRATION.id ? MISMATCH : { result: s.anchor_status === 'confirmed' ? 'match' : 'not_anchored_yet', fields: [], extra: 'LEAK-CHECK' },
    ]),
  );
}

const ALERTS = new Map([
  [FLAGGED.id, [{ id: 'a1000000-0000-4000-8000-000000000001', type: 'quantity_discrepancy', status: 'open', details: 'LEAK-ALERT-DETAILS', review_notes: 'LEAK-NOTES' }]],
  [REJECTED.id, [{ id: 'a1000000-0000-4000-8000-000000000002', type: 'quantity_discrepancy', status: 'reviewed' }]],
]);

function facts(steps, overrides = {}) {
  return { held: true, hasAcceptedPurchase: false, hasOwnHandoff: false, checks: checksFor(steps), alerts: ALERTS, ...overrides };
}

function view(viewer, stage, factOverrides = {}) {
  const steps = STEPS_BY_STAGE[stage];
  return discloseConsignment(viewer, consignment(stage), steps, facts(steps, factOverrides));
}

const stepOf = (body, step) => body.steps.find((s) => s.id === step.id);
const hexOf = (bytes) => `0x${bytes.toString('hex')}`;

// Every key and every string anywhere in a body.
function walk(value, keys = [], strings = []) {
  if (typeof value === 'string') strings.push(value);
  else if (Array.isArray(value)) value.forEach((v) => walk(v, keys, strings));
  else if (value && typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) {
      keys.push(k);
      walk(v, keys, strings);
    }
  }
  return { keys, strings };
}

const weightsOf = (steps) => steps.map((s) => s.weight_mg);
const coordsOf = (steps) => steps.flatMap((s) => [s.latitude, s.longitude]);
const usernamesOf = (steps) => steps.map((s) => s.actor_username);
const evidenceOf = (steps) => steps.flatMap((s) => [s.signed_payload, s.signature.toString('base64'), s.signer_public_key.toString('base64')]);
const hashesOf = (steps) => steps.filter((s) => s.chain_tx_hash).map((s) => hexOf(s.chain_tx_hash));
const ALL = STEPS_BY_STAGE.purchased;

// Every role and state in the table, with what must never appear in that body.
const SCENARIOS = [
  {
    label: 'transporter before their own handoff',
    run: () => view(VIEWERS.transporter, 'in_transit'),
    hidden: [...weightsOf(ALL), ...coordsOf(ALL), ...usernamesOf(ALL), ...evidenceOf(ALL), ...hashesOf(ALL), 'flagged-user', 'rejected-user'],
  },
  {
    label: 'transporter after their own handoff',
    run: () => view(VIEWERS.transporter, 'purchased', { hasOwnHandoff: true }),
    hidden: [...coordsOf(ALL), ...usernamesOf(ALL), ...evidenceOf(ALL), FLAGGED.weight_mg, REJECTED.weight_mg],
  },
  {
    label: 'buyer at in_transit, no purchase',
    run: () => view(VIEWERS.buyer, 'in_transit'),
    hidden: [...coordsOf(ALL), ...evidenceOf(ALL), FLAGGED.weight_mg, REJECTED.weight_mg, 'flagged-user', 'rejected-user'],
  },
  {
    label: 'buyer after their own purchase',
    run: () => view(VIEWERS.buyer, 'purchased', { hasAcceptedPurchase: true }),
    hidden: [...coordsOf([FLAGGED, REJECTED]), ...evidenceOf([FLAGGED, REJECTED]), FLAGGED.weight_mg, REJECTED.weight_mg, 'flagged-user'],
  },
  {
    label: 'officer',
    run: () => view(VIEWERS.officer, 'purchased'),
    hidden: [],
  },
];

// Never in any body, under any key name we might use for them.
const FORBIDDEN_KEYS = [
  'full_name', 'fullName', 'licence_number', 'licenceNumber', 'actor_ref', 'actorRef', 'anchor_error', 'anchorError',
  'anchor_nonce', 'anchorNonce', 'nonce', 'actor_id', 'actorId', 'userId', 'user_id', 'miner_id', 'minerId',
  'data_hash', 'dataHash', 'block_number', 'blockNumber', 'secret_column', 'details', 'review_notes',
];
const NEVER_VALUES = [
  ...Object.values(IDS),
  ...ALL.flatMap((s) => [s.full_name, s.licence_number, hexOf(s.actor_ref), s.anchor_error, s.secret_column, hexOf(s.data_hash)]),
  'LEAK-CONSIGNMENT-COLUMN', 'LEAK-CHECK', 'LEAK-ALERT-DETAILS', 'LEAK-NOTES', 'Viewer Full Name', 'viewer-transporter',
];

describe('who can open', () => {
  it.each(['registered', 'in_transit', 'purchased'])('a transporter opens any consignment (%s)', (stage) => {
    expect(view(VIEWERS.transporter, stage)).not.toBeNull();
  });

  it.each(['registered', 'in_transit', 'purchased'])('an officer opens any consignment (%s)', (stage) => {
    expect(view(VIEWERS.officer, stage)).not.toBeNull();
  });

  it('a buyer without an accepted purchase: not visible at registered', () => {
    expect(view(VIEWERS.buyer, 'registered')).toBeNull();
  });

  it('a buyer without an accepted purchase: visible at in_transit', () => {
    expect(view(VIEWERS.buyer, 'in_transit')).not.toBeNull();
  });

  it('a buyer: not visible after another buyer\'s purchase', () => {
    expect(view(VIEWERS.otherBuyer, 'purchased', { hasAcceptedPurchase: false })).toBeNull();
  });

  it('a buyer: visible after their own accepted purchase', () => {
    expect(view(VIEWERS.buyer, 'purchased', { hasAcceptedPurchase: true })).not.toBeNull();
  });

  it.each([
    ['a miner', { id: IDS.miner, role: 'miner' }],
    ['an admin', { id: IDS.officer, role: 'admin' }],
    ['no viewer', undefined],
  ])('refuses %s, which the route guard never lets through', (_label, viewer) => {
    expect(() => discloseConsignment(viewer, consignment('in_transit'), [], facts([]))).toThrow(TypeError);
  });
});

describe('steps listed', () => {
  it.each([
    ['a transporter', () => view(VIEWERS.transporter, 'purchased', { hasOwnHandoff: true })],
    ['a buyer in transit', () => view(VIEWERS.buyer, 'in_transit')],
    ['the owning buyer', () => view(VIEWERS.buyer, 'purchased', { hasAcceptedPurchase: true })],
  ])('%s sees accepted steps only, with no review status or alerts', (_label, run) => {
    const body = run();

    expect(body.steps.map((s) => s.id)).not.toContain(FLAGGED.id);
    expect(body.steps.map((s) => s.id)).not.toContain(REJECTED.id);
    expect(body.steps.map((s) => s.id)).toContain(HANDOFF.id); // cleared counts as accepted
    for (const step of body.steps) {
      expect(step).not.toHaveProperty('reviewStatus');
      expect(step).not.toHaveProperty('alerts');
    }
  });

  it('an officer sees every step, flagged and rejected included, in custody order', () => {
    const body = view(VIEWERS.officer, 'purchased');

    expect(body.steps.map((s) => s.id)).toEqual(ALL.map((s) => s.id));
    expect(body.steps.map((s) => s.reviewStatus)).toEqual(['passed', 'cleared', 'flagged', 'rejected', 'passed']);
  });

  it("an officer sees each step's alerts as id, type and status only", () => {
    const body = view(VIEWERS.officer, 'purchased');

    expect(stepOf(body, FLAGGED).alerts).toEqual([{ id: 'a1000000-0000-4000-8000-000000000001', type: 'quantity_discrepancy', status: 'open' }]);
    expect(stepOf(body, REGISTRATION).alerts).toEqual([]);
  });

  it('keeps the order the service gives', () => {
    const steps = [HANDOFF, REGISTRATION];
    const body = discloseConsignment(VIEWERS.officer, consignment('in_transit'), steps, facts(steps));

    expect(body.steps.map((s) => s.id)).toEqual([HANDOFF.id, REGISTRATION.id]);
  });
});

describe('weights (blind measurement)', () => {
  it('a transporter before their own handoff sees no weight and no transaction hash', () => {
    const body = view(VIEWERS.transporter, 'in_transit');

    expect(body.consignment.weightsHidden).toBe(true);
    for (const step of body.steps) {
      expect(step).not.toHaveProperty('weightMg');
      expect(step.anchor).toEqual({ status: expect.any(String) });
    }
    // The chain check result itself still shows.
    expect(stepOf(body, REGISTRATION).check).toEqual({ result: 'mismatch' });
  });

  it('a transporter after their own handoff sees weights and hashes', () => {
    const body = view(VIEWERS.transporter, 'purchased', { hasOwnHandoff: true });

    expect(body.consignment.weightsHidden).toBe(false);
    expect(stepOf(body, REGISTRATION).weightMg).toBe('1500000');
    expect(stepOf(body, PURCHASE).weightMg).toBe('1494500');
    expect(stepOf(body, REGISTRATION).anchor).toEqual({ status: 'confirmed', chainTxHash: hexOf(REGISTRATION.chain_tx_hash) });
  });

  it.each([
    ['a buyer in transit', () => view(VIEWERS.buyer, 'in_transit')],
    ['the owning buyer', () => view(VIEWERS.buyer, 'purchased', { hasAcceptedPurchase: true })],
    ['an officer', () => view(VIEWERS.officer, 'purchased')],
  ])('%s sees weights, as text', (_label, run) => {
    const body = run();

    expect(body.consignment.weightsHidden).toBe(false);
    expect(stepOf(body, REGISTRATION).weightMg).toBe('1500000');
  });
});

describe('GPS and zones', () => {
  it.each([
    ['a transporter before their handoff', () => view(VIEWERS.transporter, 'in_transit')],
    ['a transporter after their handoff', () => view(VIEWERS.transporter, 'purchased', { hasOwnHandoff: true })],
    ['a buyer in transit', () => view(VIEWERS.buyer, 'in_transit')],
  ])('%s gets the zone name and no coordinates', (_label, run) => {
    const body = run();

    for (const step of body.steps) expect(step).not.toHaveProperty('location');
    expect(stepOf(body, REGISTRATION).zoneName).toBe('Campus Zone');
  });

  it.each([
    ['the owning buyer', () => view(VIEWERS.buyer, 'purchased', { hasAcceptedPurchase: true })],
    ['an officer', () => view(VIEWERS.officer, 'purchased')],
  ])('%s gets coordinates as text, and the zone name', (_label, run) => {
    const body = run();

    expect(stepOf(body, REGISTRATION).location).toEqual({ latitude: '-15.419012', longitude: '28.288105' });
    expect(stepOf(body, REGISTRATION).zoneName).toBe('Campus Zone');
  });

  it('a step outside every zone has zoneName null', () => {
    expect(stepOf(view(VIEWERS.officer, 'in_transit'), FLAGGED).zoneName).toBeNull();
  });
});

describe('actors', () => {
  it('a transporter sees roles only', () => {
    const body = view(VIEWERS.transporter, 'purchased', { hasOwnHandoff: true });

    expect(body.steps.map((s) => s.actor)).toEqual([{ role: 'miner' }, { role: 'transporter' }, { role: 'buyer' }]);
  });

  it.each([
    ['a buyer', () => view(VIEWERS.buyer, 'in_transit')],
    ['an officer', () => view(VIEWERS.officer, 'in_transit')],
  ])('%s sees role and username', (_label, run) => {
    expect(stepOf(run(), REGISTRATION).actor).toEqual({ role: 'miner', username: 'miner-user' });
  });

  it("byYou marks the viewer's own steps only, and no user id appears", () => {
    const body = view(VIEWERS.transporter, 'purchased', { hasOwnHandoff: true });

    expect(body.steps.map((s) => s.byYou)).toEqual([false, true, false]);
    expect(walk(body).strings).not.toContain(IDS.transporter);
  });
});

describe('evidence', () => {
  it.each([
    ['the owning buyer', () => view(VIEWERS.buyer, 'purchased', { hasAcceptedPurchase: true })],
    ['an officer', () => view(VIEWERS.officer, 'purchased')],
  ])('%s gets the signed payload, and signature and key in base64', (_label, run) => {
    expect(stepOf(run(), HANDOFF).evidence).toEqual({
      signedPayload: HANDOFF.signed_payload,
      signature: HANDOFF.signature.toString('base64'),
      signerPublicKey: HANDOFF.signer_public_key.toString('base64'),
    });
  });

  it.each([
    ['a transporter after their handoff', () => view(VIEWERS.transporter, 'purchased', { hasOwnHandoff: true })],
    ['a buyer in transit', () => view(VIEWERS.buyer, 'in_transit')],
  ])('%s gets no evidence', (_label, run) => {
    for (const step of run().steps) expect(step).not.toHaveProperty('evidence');
  });
});

describe('chain check', () => {
  it('an officer sees mismatch field names and the reason', () => {
    expect(stepOf(view(VIEWERS.officer, 'in_transit'), REGISTRATION).check).toEqual({
      result: 'mismatch',
      fields: ['weight_mg', 'data_hash'],
      reason: 'SOME_REASON',
    });
  });

  it.each([
    ['a transporter', () => view(VIEWERS.transporter, 'in_transit')],
    ['a buyer in transit', () => view(VIEWERS.buyer, 'in_transit')],
    ['the owning buyer', () => view(VIEWERS.buyer, 'purchased', { hasAcceptedPurchase: true })],
  ])('%s sees the result only, never the field names', (_label, run) => {
    const body = run();

    expect(stepOf(body, REGISTRATION).check).toEqual({ result: 'mismatch' });
    expect(stepOf(body, HANDOFF).check).toEqual({ result: 'match' });
  });

  it('a listed step with no check result is a bug in the caller', () => {
    expect(() =>
      discloseConsignment(VIEWERS.officer, consignment('registered'), [REGISTRATION], facts([REGISTRATION], { checks: new Map() })),
    ).toThrow(TypeError);
  });
});

describe('what everyone sees', () => {
  it.each(SCENARIOS.map((s) => [s.label, s]))('%s: held, stage, mineral, code, times and anchor status', (_label, scenario) => {
    const body = scenario.run();

    expect(body.consignment).toMatchObject({ id: CONSIGNMENT_ID, qrCode: 'MC-DEMO-000001', mineral: 'gold', held: true });
    expect(['in_transit', 'purchased']).toContain(body.consignment.stage);
    const registration = stepOf(body, REGISTRATION);
    expect(registration).toMatchObject({
      type: 'registration',
      capturedAt: '2026-11-11T08:00:00.000Z',
      receivedAt: '2026-11-11T08:05:00.000Z',
      anchor: { status: 'confirmed' },
    });
  });

  it('held false is shown as false', () => {
    expect(view(VIEWERS.officer, 'registered', { held: false }).consignment.held).toBe(false);
  });

  it('where hashes are shown: a submitted step has its hash, a pending one null', () => {
    expect(stepOf(view(VIEWERS.officer, 'purchased'), PURCHASE).anchor).toEqual({ status: 'submitted', chainTxHash: hexOf(PURCHASE.chain_tx_hash) });
    expect(stepOf(view(VIEWERS.officer, 'in_transit'), FLAGGED).anchor).toEqual({ status: 'pending', chainTxHash: null });
  });
});

describe('deep scans of every body', () => {
  const rows = SCENARIOS.map((s) => [s.label, s]);

  it.each(rows)('%s: no forbidden key anywhere', (_label, scenario) => {
    const { keys } = walk(scenario.run());

    for (const key of FORBIDDEN_KEYS) expect(keys).not.toContain(key);
  });

  it.each(rows)('%s: no name, licence, reference, error, id or unknown column value anywhere', (_label, scenario) => {
    const text = JSON.stringify(scenario.run());

    for (const value of NEVER_VALUES) expect(text).not.toContain(value);
  });

  it.each(rows)('%s: no value that only a hidden field holds', (_label, scenario) => {
    const text = JSON.stringify(scenario.run());

    for (const value of scenario.hidden) expect(text).not.toContain(value);
  });

  it.each(rows)('%s: the body is frozen all the way down', (_label, scenario) => {
    const check = (value) => {
      if (value && typeof value === 'object') {
        expect(Object.isFrozen(value)).toBe(true);
        Object.values(value).forEach(check);
      }
    };
    check(scenario.run());
  });
});

describe('captured_at given as text (B2.4 selects it so)', () => {
  const withTime = (text) => {
    const step = { ...REGISTRATION, captured_at: text };
    return discloseConsignment(VIEWERS.officer, consignment('registered'), [step], facts([step])).steps[0];
  };

  it('ISO text with milliseconds is shown as it is', () => {
    expect(withTime('2026-11-10T08:00:00.000Z').capturedAt).toBe('2026-11-10T08:00:00.000Z');
  });

  it('six fraction digits (an edited row) are shown cut to milliseconds, still ISO', () => {
    expect(withTime('2026-11-10T08:00:00.000001Z').capturedAt).toBe('2026-11-10T08:00:00.000Z');
  });

  it.each(['2026-11-10 08:00:00', '2026-11-10T08:00:00Z', 'yesterday'])('refuses time text %s', (text) => {
    expect(() => withTime(text)).toThrow(TypeError);
  });
});

describe('canSeeConsignment', () => {
  it.each([
    ['transporter', VIEWERS.transporter, 'registered', {}, true],
    ['buyer at registered', VIEWERS.buyer, 'registered', {}, false],
    ['buyer in transit', VIEWERS.buyer, 'in_transit', {}, true],
    ["buyer after another buyer's purchase", VIEWERS.otherBuyer, 'purchased', {}, false],
    ['owning buyer', VIEWERS.buyer, 'purchased', { hasAcceptedPurchase: true }, true],
    ['officer', VIEWERS.officer, 'registered', {}, true],
  ])('%s: the same answer as the body', (_label, viewer, stage, overrides, expected) => {
    const f = facts(STEPS_BY_STAGE[stage], overrides);

    expect(canSeeConsignment(viewer, consignment(stage), f)).toBe(expected);
    expect(discloseConsignment(viewer, consignment(stage), STEPS_BY_STAGE[stage], f) !== null).toBe(expected);
  });

  it('refuses a role the route guard never lets through', () => {
    expect(() => canSeeConsignment({ id: IDS.miner, role: 'miner' }, consignment('registered'), facts([]))).toThrow(TypeError);
  });
});

describe('field by field', () => {
  it('an unknown column added to any input never appears in the output', () => {
    const steps = STEPS_BY_STAGE.purchased.map((s) => ({ ...s, brand_new_column: 'NEW-COLUMN-VALUE' }));
    const c = { ...consignment('purchased'), brand_new_column: 'NEW-COLUMN-VALUE' };
    const f = facts(steps, { hasAcceptedPurchase: true, unexpected_fact: 'NEW-COLUMN-VALUE' });

    for (const viewer of [VIEWERS.officer, VIEWERS.buyer]) {
      const body = discloseConsignment(viewer, c, steps, f);
      const { keys } = walk(body);

      expect(keys).not.toContain('brand_new_column');
      expect(keys).not.toContain('unexpected_fact');
      expect(JSON.stringify(body)).not.toContain('NEW-COLUMN-VALUE');
    }
  });

  it('a step has exactly the keys its viewer may have', () => {
    const officer = stepOf(view(VIEWERS.officer, 'purchased'), HANDOFF);
    const transporter = stepOf(view(VIEWERS.transporter, 'in_transit'), HANDOFF);

    expect(Object.keys(officer).sort()).toEqual(
      ['actor', 'alerts', 'anchor', 'byYou', 'capturedAt', 'check', 'evidence', 'id', 'location', 'receivedAt', 'reviewStatus', 'type', 'weightMg', 'zoneName'],
    );
    expect(Object.keys(transporter).sort()).toEqual(['actor', 'anchor', 'byYou', 'capturedAt', 'check', 'id', 'receivedAt', 'type', 'zoneName']);
  });
});
