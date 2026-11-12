import { describe, it, expect } from 'vitest';
import { ROLES, SIGNING_ROLES } from '../src/roles.js';
import { SELF_REGISTER_ROLES } from '../src/schemas/auth.js';

describe('SIGNING_ROLES', () => {
  it('is the three custody roles, in custody order', () => {
    expect(SIGNING_ROLES).toEqual(['miner', 'transporter', 'buyer']);
  });

  it('leaves out officers and admins, who never sign a step', () => {
    expect(SIGNING_ROLES).not.toContain('officer');
    expect(SIGNING_ROLES).not.toContain('admin');
  });

  it('uses only real role names', () => {
    for (const role of SIGNING_ROLES) expect(ROLES).toContain(role);
  });

  it('cannot be changed at run time', () => {
    expect(Object.isFrozen(SIGNING_ROLES)).toBe(true);
  });

  it('is a separate list from SELF_REGISTER_ROLES, even though the two match today', () => {
    // Same contents now; different objects so one rule can change without the other.
    expect(SIGNING_ROLES).toEqual(SELF_REGISTER_ROLES);
    expect(SIGNING_ROLES).not.toBe(SELF_REGISTER_ROLES);
  });
});
