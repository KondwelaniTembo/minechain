import { describe, it, expect } from 'vitest';
import {
  ALERT_TYPES,
  ALERT_SEVERITIES,
  CHECKS,
  FLAGGED_MESSAGES,
  QUANTITY_THRESHOLD_PERCENT,
  checkSignature,
  checkDuplicate,
  checkHandoffOrder,
  checkQuantity,
  checkGpsZone,
  runChecks,
  reviewStatusFor,
  mostSevereFinding,
  flaggedCodeFor,
} from '../src/services/anomalyChecks.js';
import { matchZone, ZONE_TOLERANCE_METRES } from '../src/services/zoneMatch.js';

const FINGERPRINT = 'ab'.repeat(32);
const ACTOR = '6f1d2c3a-0000-4000-8000-000000000001';
const OTHER_ACTOR = '6f1d2c3a-0000-4000-8000-000000000002';
const step = (type, overrides = {}) => ({ type, actorId: ACTOR, weightMg: '1500000', ...overrides });

describe('the lists match the alerts migration', () => {
  it('has the six alert types of alerts_type_valid', () => {
    expect([...ALERT_TYPES].sort()).toEqual(
      ['duplicate_consignment', 'gps_zone', 'handoff_order', 'invalid_signature', 'quantity_discrepancy', 'record_tampered'],
    );
  });

  it('has the three severities of alerts_severity_valid', () => {
    expect(ALERT_SEVERITIES).toEqual(['low', 'medium', 'high']);
  });
});

describe('checkSignature', () => {
  it('finds nothing when the signature verified', () => {
    expect(checkSignature({ verified: true, keyFingerprint: FINGERPRINT })).toBeNull();
  });

  it('raises a high invalid_signature alert naming the key by fingerprint', () => {
    expect(checkSignature({ verified: false, keyFingerprint: FINGERPRINT })).toEqual({
      type: 'invalid_signature',
      severity: 'high',
      details: { keyFingerprint: FINGERPRINT },
    });
  });

  it.each([
    ['undefined', undefined],
    ['the string "true"', 'true'],
    ['1', 1],
  ])('treats verified = %s as not verified, so only a real true passes', (_label, verified) => {
    expect(checkSignature({ verified, keyFingerprint: FINGERPRINT })?.type).toBe('invalid_signature');
  });
});

describe('CHECKS', () => {
  it('runs the five checks in order: signature, duplicate, handoff order, quantity, GPS zone', () => {
    expect(CHECKS).toEqual([checkSignature, checkDuplicate, checkHandoffOrder, checkQuantity, checkGpsZone]);
  });

  it('finds nothing new while sync gathers no context for the new checks (until 9.3)', () => {
    // Exactly the context sync passes today: the four new checks are not asked.
    for (const type of ['registration', 'handoff', 'purchase']) {
      expect(runChecks({ step: step(type), verified: true, keyFingerprint: FINGERPRINT })).toEqual([]);
    }
  });

  it('cannot be changed at run time', () => {
    expect(Object.isFrozen(CHECKS)).toBe(true);
  });
});

describe('runChecks', () => {
  it('returns no findings for a step that passes, so it is passed', () => {
    const findings = runChecks({ verified: true, keyFingerprint: FINGERPRINT });

    expect(findings).toEqual([]);
    expect(reviewStatusFor(findings)).toBe('passed');
  });

  it('returns the signature finding for a bad signature, so it is flagged', () => {
    const findings = runChecks({ verified: false, keyFingerprint: FINGERPRINT });

    expect(findings.map((f) => f.type)).toEqual(['invalid_signature']);
    expect(reviewStatusFor(findings)).toBe('flagged');
  });

  it('runs every check given, in order, and keeps each finding', () => {
    const quantity = () => ({ type: 'quantity_discrepancy', severity: 'medium', details: { differencePercent: 12 } });
    const zone = () => ({ type: 'gps_zone', severity: 'medium', details: {} });

    const findings = runChecks({ verified: false, keyFingerprint: FINGERPRINT }, [checkSignature, quantity, zone]);

    expect(findings.map((f) => f.type)).toEqual(['invalid_signature', 'quantity_discrepancy', 'gps_zone']);
  });

  it('passes the same context to every check', () => {
    const seen = [];
    const spy = (context) => {
      seen.push(context);
      return null;
    };
    const context = { verified: true, keyFingerprint: FINGERPRINT };

    runChecks(context, [spy, spy]);

    expect(seen).toEqual([context, context]);
  });

  describe('refuses a finding the alerts table would refuse', () => {
    it.each([
      ['an unknown type', () => ({ type: 'weight_drift', severity: 'low', details: {} }), 'unknown alert type'],
      ['an unknown severity', () => ({ type: 'gps_zone', severity: 'critical', details: {} }), 'unknown severity'],
      ['details that are a list', () => ({ type: 'gps_zone', severity: 'low', details: [] }), 'details as an object'],
      ['no details', () => ({ type: 'gps_zone', severity: 'low' }), 'details as an object'],
      ['undefined instead of null for "nothing found"', () => undefined, 'unknown alert type'],
    ])('%s', (_label, check, message) => {
      expect(() => runChecks({}, [check])).toThrow(message);
    });

    it('two findings of the same type, since alerts allow one per rule per step', () => {
      const twice = () => ({ type: 'gps_zone', severity: 'low', details: {} });

      expect(() => runChecks({}, [twice, twice])).toThrow('two checks returned the alert type gps_zone');
    });

    it('names the check in the message, so a mistake is easy to find', () => {
      function checkBrokenZone() {
        return { type: 'zone', severity: 'low', details: {} };
      }

      expect(() => runChecks({}, [checkBrokenZone])).toThrow('checkBrokenZone returned an unknown alert type');
    });
  });
});

describe('reviewStatusFor', () => {
  it.each([
    [[], 'passed'],
    [[{ type: 'invalid_signature' }], 'flagged'],
    [[{ type: 'gps_zone' }, { type: 'handoff_order' }], 'flagged'],
  ])('%j gives %s', (findings, status) => {
    expect(reviewStatusFor(findings)).toBe(status);
  });
});

describe('absent context: a check that was not asked finds nothing', () => {
  // undefined means sync did not gather that part of the context. Each check must then
  // stay silent, whatever else the context says, so adding checks never changes sync until
  // sync supplies their context.
  it.each([
    ['checkDuplicate', checkDuplicate, 'registration'],
    ['checkHandoffOrder', checkHandoffOrder, 'purchase'],
    ['checkQuantity', checkQuantity, 'handoff'],
    ['checkGpsZone', checkGpsZone, 'registration'],
  ])('%s returns null', (_name, check, type) => {
    expect(check({ step: step(type, { weightMg: '1' }), verified: false })).toBeNull();
    expect(check({})).toBeNull();
  });
});

describe('checkDuplicate', () => {
  const original = { transactionId: 'aaaaaaaa-0000-4000-8000-000000000001', actorId: OTHER_ACTOR, mineral: 'gold', reviewStatus: 'passed' };

  it('finds nothing for a new QR code', () => {
    expect(checkDuplicate({ existingRegistration: null, step: step('registration', { mineral: 'gold' }) })).toBeNull();
  });

  it('raises a high duplicate_consignment alert, with ids only', () => {
    expect(checkDuplicate({ existingRegistration: original, step: step('registration', { mineral: 'copper' }) })).toEqual({
      type: 'duplicate_consignment',
      severity: 'high',
      details: {
        originalTransactionId: original.transactionId,
        originalReviewStatus: 'passed',
        sameMiner: false,
        mineral: 'copper',
        originalMineral: 'gold',
      },
    });
  });

  it('says when the same miner registered the record twice', () => {
    const finding = checkDuplicate({ existingRegistration: { ...original, actorId: ACTOR }, step: step('registration', { mineral: 'gold' }) });

    expect(finding.details.sameMiner).toBe(true);
  });

  it.each(['handoff', 'purchase'])('ignores a %s', (type) => {
    expect(checkDuplicate({ existingRegistration: original, step: step(type) })).toBeNull();
  });
});

describe('checkHandoffOrder', () => {
  it('raises a medium handoff_order alert for a handoff after the purchase (it may be a late relay)', () => {
    expect(checkHandoffOrder({ consignmentStage: 'purchased', step: step('handoff') })).toEqual({
      type: 'handoff_order',
      severity: 'medium',
      details: { consignmentStage: 'purchased', stepType: 'handoff' },
    });
  });

  it('raises a high handoff_order alert for a second purchase (sold twice)', () => {
    expect(checkHandoffOrder({ consignmentStage: 'purchased', step: step('purchase') })).toMatchObject({
      type: 'handoff_order',
      severity: 'high',
      details: { stepType: 'purchase' },
    });
  });

  it.each([
    ['a handoff at registered', 'registered', 'handoff'],
    ['a handoff at in_transit (a relay)', 'in_transit', 'handoff'],
    ['a purchase at in_transit', 'in_transit', 'purchase'],
    // Deferred by sync instead: the handoff has most likely not arrived yet.
    ['a purchase at registered', 'registered', 'purchase'],
    ['a registration', 'purchased', 'registration'],
  ])('finds nothing for %s', (_label, consignmentStage, type) => {
    expect(checkHandoffOrder({ consignmentStage, step: step(type) })).toBeNull();
  });
});

describe('checkQuantity', () => {
  const REGISTRATION = { stepId: 'r', weightMg: '1500000' };
  const handoff = (weightMg, baselines) => checkQuantity({ step: step('handoff', { weightMg }), baselines });
  // The first handoff: the previous accepted step is the registration itself.
  const firstHandoff = (weightMg) => handoff(weightMg, { previous: REGISTRATION, registration: REGISTRATION });

  it('uses the 10% of FR-08', () => {
    expect(QUANTITY_THRESHOLD_PERCENT).toBe(10);
  });

  describe('the 10% boundary, both ways (more than 10% is flagged; exactly 10% passes)', () => {
    it.each([
      ['exactly 10% lighter', '1350000', false],
      ['1 mg more than 10% lighter', '1349999', true],
      ['exactly 10% heavier', '1650000', false],
      ['1 mg more than 10% heavier', '1650001', true],
      ['unchanged', '1500000', false],
      ['slightly lighter', '1495000', false],
    ])('%s: flagged %s', (_label, weightMg, flagged) => {
      expect(firstHandoff(weightMg) !== null).toBe(flagged);
    });
  });

  it('raises a medium alert with every value as text, and the signed difference', () => {
    expect(firstHandoff('1200000')).toEqual({
      type: 'quantity_discrepancy',
      severity: 'medium',
      details: {
        weightMg: '1200000',
        thresholdPercent: 10,
        failedBaselines: ['registration'],
        // Compared once: for the first handoff the previous step is the registration.
        registration: { stepId: 'r', weightMg: '1500000', differenceMg: '-300000', exceeded: true },
      },
    });
  });

  it('stays exact beyond 2^53, where a JavaScript number would round', () => {
    // 10% of 90071992547409930 is 9007199254740993, which a float cannot hold exactly.
    const baseline = { stepId: 'r', weightMg: '90071992547409930' };
    const at = (weightMg) => handoff(weightMg, { previous: baseline, registration: baseline });

    expect(at('81064793292668937')).toBeNull(); // exactly 10% lighter
    expect(at('81064793292668936')).not.toBeNull(); // 1 mg more
  });

  describe('two baselines: the previous accepted step and the registration', () => {
    it('catches gradual loss: each step under 10% from the previous, more than 10% from the registration', () => {
      // 1,500,000 -> 1,400,000 (-6.7%) -> 1,320,000 (-5.7% from the previous, -12% overall).
      const finding = handoff('1320000', { previous: { stepId: 'h1', weightMg: '1400000' }, registration: REGISTRATION });

      expect(finding.details.failedBaselines).toEqual(['registration']);
      expect(finding.details.previous).toEqual({ stepId: 'h1', weightMg: '1400000', differenceMg: '-80000', exceeded: false });
      expect(finding.details.registration).toEqual({ stepId: 'r', weightMg: '1500000', differenceMg: '-180000', exceeded: true });
    });

    it('catches a sudden jump from the previous step that is still within 10% of the registration', () => {
      // 1,500,000 -> 1,365,000 (-9%) -> 1,530,000 (+12.1% from the previous, +2% overall).
      const finding = handoff('1530000', { previous: { stepId: 'h1', weightMg: '1365000' }, registration: REGISTRATION });

      expect(finding.details.failedBaselines).toEqual(['previous']);
    });

    it('names both when both are exceeded', () => {
      const finding = handoff('1000000', { previous: { stepId: 'h1', weightMg: '1400000' }, registration: REGISTRATION });

      expect(finding.details.failedBaselines).toEqual(['previous', 'registration']);
    });

    it('finds nothing when both are within 10%', () => {
      expect(handoff('1400000', { previous: { stepId: 'h1', weightMg: '1450000' }, registration: REGISTRATION })).toBeNull();
    });

    it('uses whichever baseline exists', () => {
      expect(handoff('1000000', { previous: { stepId: 'h1', weightMg: '1400000' }, registration: null })?.details.failedBaselines).toEqual([
        'previous',
      ]);
      expect(handoff('1000000', { previous: null, registration: REGISTRATION })?.details.failedBaselines).toEqual(['registration']);
    });
  });

  it('finds nothing with no accepted baseline at all', () => {
    expect(handoff('1', { previous: null, registration: null })).toBeNull();
  });

  it('applies to purchases too', () => {
    const finding = checkQuantity({
      step: step('purchase', { weightMg: '1000000' }),
      baselines: { previous: REGISTRATION, registration: REGISTRATION },
    });

    expect(finding?.type).toBe('quantity_discrepancy');
  });

  it('ignores a registration, which has no earlier stage', () => {
    expect(
      checkQuantity({ step: step('registration', { weightMg: '1' }), baselines: { previous: REGISTRATION, registration: REGISTRATION } }),
    ).toBeNull();
  });

  it.each([
    ['a float-looking weight', '1500000.0'],
    ['a number instead of text', 1500000],
    ['zero', '0'],
  ])('refuses %s, which would mean a bug upstream', (_label, weightMg) => {
    expect(() => firstHandoff(weightMg)).toThrow(TypeError);
  });
});

describe('checkGpsZone', () => {
  // A square of about 220 x 210 m near Lusaka, and points placed by plain degree offsets
  // (0.0001 degree of latitude is about 11 m).
  const ZONE = {
    id: 'z1',
    name: 'Demo zone',
    boundary: [
      [-15.421, 28.289],
      [-15.421, 28.291],
      [-15.419, 28.291],
      [-15.419, 28.289],
    ],
  };
  const gps = (lat, lng, zones = [ZONE], type = 'registration') =>
    checkGpsZone({ step: step(type), zoneMatch: matchZone({ lat, lng }, zones) });

  it('finds nothing for a registration inside a zone', () => {
    expect(gps(-15.42, 28.29)).toBeNull();
  });

  it('finds nothing for a registration just outside, within the tolerance (about 11 m)', () => {
    expect(gps(-15.4189, 28.29)).toBeNull();
  });

  it('raises a medium alert outside every zone, naming the nearest with a whole-metre distance', () => {
    // 0.001 degree of latitude north of the zone's north edge: about 111 m.
    const finding = gps(-15.418, 28.29);

    expect(finding).toEqual({
      type: 'gps_zone',
      severity: 'medium',
      details: { nearestZoneId: 'z1', nearestZoneName: 'Demo zone', distanceMetres: 111, toleranceMetres: ZONE_TOLERANCE_METRES },
    });
    expect(Number.isInteger(finding.details.distanceMetres)).toBe(true);
  });

  it('flags every registration when no active zone exists at all', () => {
    expect(gps(-15.42, 28.29, [])).toEqual({
      type: 'gps_zone',
      severity: 'medium',
      details: { noActiveZones: true, toleranceMetres: ZONE_TOLERANCE_METRES },
    });
  });

  it.each(['handoff', 'purchase'])('never flags a %s (they happen outside extraction zones)', (type) => {
    expect(gps(-15.5, 28.5, [ZONE], type)).toBeNull();
    expect(gps(-15.5, 28.5, [], type)).toBeNull();
  });
});

describe('choosing the code for a flagged step', () => {
  const finding = (type, severity) => ({ type, severity, details: {} });

  it('picks the most severe finding', () => {
    const findings = [finding('quantity_discrepancy', 'medium'), finding('duplicate_consignment', 'high')];

    expect(mostSevereFinding(findings).type).toBe('duplicate_consignment');
    expect(flaggedCodeFor(findings)).toBe('DUPLICATE_CONSIGNMENT');
  });

  it('breaks a tie by check order, which is the order the findings arrive in', () => {
    expect(flaggedCodeFor([finding('quantity_discrepancy', 'medium'), finding('gps_zone', 'medium')])).toBe('QUANTITY_DISCREPANCY');
  });

  it('keeps the first of several high findings', () => {
    expect(flaggedCodeFor([finding('invalid_signature', 'high'), finding('handoff_order', 'high')])).toBe('INVALID_SIGNATURE');
  });

  it('has no code when there is no finding', () => {
    expect(mostSevereFinding([])).toBeNull();
    expect(flaggedCodeFor([])).toBeNull();
  });

  it('works on what runChecks really returns: a forged second purchase is named by its signature', () => {
    const findings = runChecks({
      step: step('purchase', { weightMg: '1000000' }),
      verified: false,
      keyFingerprint: FINGERPRINT,
      consignmentStage: 'purchased',
      baselines: { previous: { stepId: 'r', weightMg: '1500000' }, registration: { stepId: 'r', weightMg: '1500000' } },
    });

    expect(findings.map((f) => f.type)).toEqual(['invalid_signature', 'handoff_order', 'quantity_discrepancy']);
    expect(flaggedCodeFor(findings)).toBe('INVALID_SIGNATURE');
  });

  it('names a medium-only step by its first finding in check order', () => {
    const findings = runChecks({
      step: step('handoff', { weightMg: '1000000' }),
      verified: true,
      consignmentStage: 'purchased',
      baselines: { previous: null, registration: { stepId: 'r', weightMg: '1500000' } },
    });

    expect(findings.map((f) => [f.type, f.severity])).toEqual([
      ['handoff_order', 'medium'],
      ['quantity_discrepancy', 'medium'],
    ]);
    expect(flaggedCodeFor(findings)).toBe('HANDOFF_ORDER');
  });
});

describe('FLAGGED_MESSAGES', () => {
  // A context that makes each check fire, so the codes come from the checks themselves.
  const TRIGGERS = [
    { step: step('registration'), verified: false, keyFingerprint: FINGERPRINT },
    {
      step: step('registration', { mineral: 'gold' }),
      existingRegistration: { transactionId: 't', actorId: ACTOR, mineral: 'gold', reviewStatus: 'passed' },
    },
    { step: step('handoff'), consignmentStage: 'purchased' },
    { step: step('handoff', { weightMg: '1' }), baselines: { previous: null, registration: { stepId: 'r', weightMg: '1500000' } } },
    { step: step('registration'), zoneMatch: matchZone({ lat: 0, lng: 0 }, []) },
  ];

  it('has a plain-language message for every code the checks can produce', () => {
    const codes = TRIGGERS.map((context) => flaggedCodeFor(runChecks({ verified: true, ...context })));

    expect(codes).toEqual(['INVALID_SIGNATURE', 'DUPLICATE_CONSIGNMENT', 'HANDOFF_ORDER', 'QUANTITY_DISCREPANCY', 'GPS_ZONE']);
    for (const code of codes) {
      // Each tells the app the record was kept, so it is neither discarded nor resent.
      expect(FLAGGED_MESSAGES[code]).toMatch(/saved/);
    }
  });

  it('has a message for every sync-time alert type, and none for record_tampered (raised by verification)', () => {
    const syncTypes = ALERT_TYPES.filter((type) => type !== 'record_tampered');

    expect(Object.keys(FLAGGED_MESSAGES).sort()).toEqual(syncTypes.map((type) => type.toUpperCase()).sort());
  });

  it('keeps the signature message sync already sends, word for word', () => {
    expect(FLAGGED_MESSAGES.INVALID_SIGNATURE).toBe(
      'The record was saved, but its signature did not match your device key. An officer will review it.',
    );
  });

  it('cannot be changed at run time', () => {
    expect(Object.isFrozen(FLAGGED_MESSAGES)).toBe(true);
  });
});
