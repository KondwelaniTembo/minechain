import { describe, it, expect } from 'vitest';
import { registerSchema } from '../src/schemas/auth.js';

const valid = {
  username: 'mutale_banda',
  fullName: 'Mutale Banda',
  password: 'gold river kasempa',
  role: 'miner',
};

// Lists the fields that failed, so each test checks the rule it is about.
const failedFields = (input) => {
  const result = registerSchema.safeParse(input);
  if (result.success) return [];
  return result.error.issues.flatMap((i) => (i.code === 'unrecognized_keys' ? i.keys : [i.path.join('.')]));
};

describe('registerSchema', () => {
  describe('accepts', () => {
    it.each(['miner', 'transporter', 'buyer'])('the role %s', (role) => {
      expect(registerSchema.safeParse({ ...valid, role }).success).toBe(true);
    });

    it('an optional licence number', () => {
      const result = registerSchema.parse({ ...valid, licenceNumber: ' ZM-ASM-0042 ' });

      expect(result.licenceNumber).toBe('ZM-ASM-0042');
    });

    it('a request without a licence number', () => {
      expect(registerSchema.parse(valid)).not.toHaveProperty('licenceNumber');
    });

    it('and trims the username and full name, but never the password', () => {
      const result = registerSchema.parse({ ...valid, username: '  mutale_banda ', fullName: ' Mutale Banda ', password: ' gold river kasempa ' });

      expect(result.username).toBe('mutale_banda');
      expect(result.fullName).toBe('Mutale Banda');
      expect(result.password).toBe(' gold river kasempa ');
    });

    it('a weak password, because the policy is checked by the service, not here', () => {
      expect(registerSchema.safeParse({ ...valid, password: 'short' }).success).toBe(true);
    });
  });

  describe('roles that cannot be requested', () => {
    it.each(['officer', 'admin', 'superuser', ''])('refuses %j', (role) => {
      const result = registerSchema.safeParse({ ...valid, role });

      expect(result.success).toBe(false);
      expect(result.error.issues[0].message).toBe('must be miner, transporter or buyer');
    });
  });

  describe('fields that must never come from input', () => {
    it.each([
      ['status', { status: 'active' }],
      ['id', { id: '00000000-0000-4000-8000-000000000000' }],
      ['actorRef', { actorRef: 'abc' }],
      ['passwordHash', { passwordHash: '$argon2id$...' }],
      ['approvedBy', { approvedBy: 'someone' }],
    ])('refuses %s', (field, extra) => {
      expect(failedFields({ ...valid, ...extra })).toEqual([field]);
    });
  });

  describe('refuses', () => {
    it.each([
      ['a 2-character username', { username: 'mb' }, 'username'],
      ['a 33-character username', { username: 'a'.repeat(33) }, 'username'],
      ['a username with a space inside', { username: 'mutale banda' }, 'username'],
      ['a blank full name', { fullName: '   ' }, 'fullName'],
      ['a 101-character full name', { fullName: 'a'.repeat(101) }, 'fullName'],
      ['an empty password', { password: '' }, 'password'],
      ['a blank licence number', { licenceNumber: '  ' }, 'licenceNumber'],
      ['a password that is not text', { password: 12345678901234 }, 'password'],
    ])('%s', (_label, overrides, field) => {
      expect(failedFields({ ...valid, ...overrides })).toEqual([field]);
    });

    it.each(['username', 'fullName', 'password', 'role'])('a request without %s', (field) => {
      const { [field]: _removed, ...rest } = valid;

      expect(failedFields(rest)).toEqual([field]);
    });
  });
});
