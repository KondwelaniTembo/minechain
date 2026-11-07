import { describe, it, expect } from 'vitest';
import {
  ALERT_TYPES,
  ALERT_SEVERITIES,
  CHECKS,
  checkSignature,
  runChecks,
  reviewStatusFor,
} from '../src/services/anomalyChecks.js';

const FINGERPRINT = 'ab'.repeat(32);

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
  it('holds only the signature check for now', () => {
    expect(CHECKS).toEqual([checkSignature]);
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
