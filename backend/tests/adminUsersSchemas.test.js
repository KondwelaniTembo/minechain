import { describe, it, expect } from 'vitest';
import {
  userIdParamsSchema,
  listUsersQuerySchema,
  reasonBodySchema,
  emptyBodySchema,
  LIST_LIMIT_DEFAULT,
  LIST_LIMIT_MAX,
  LIST_OFFSET_MAX,
  REASON_MIN_LENGTH,
  REASON_MAX_LENGTH,
} from '../src/schemas/adminUsers.js';

// A fake, well-formed id (version 4, variant 8).
const USER_ID = '3f2b6c1e-0000-4000-8000-000000000001';

// Lists the fields that failed, so each test checks the rule it is about.
const failedFields = (schema, input) => {
  const result = schema.safeParse(input);
  if (result.success) return [];
  return result.error.issues.flatMap((i) => (i.code === 'unrecognized_keys' ? i.keys : [i.path.join('.')]));
};

const messages = (schema, input) => {
  const result = schema.safeParse(input);
  return result.success ? [] : result.error.issues.map((i) => i.message);
};

describe('userIdParamsSchema', () => {
  it('accepts a uuid', () => {
    expect(userIdParamsSchema.parse({ id: USER_ID })).toEqual({ id: USER_ID });
  });

  it.each([
    ['a number', '42'],
    ['a word', 'me'],
    ['a uuid with a character missing', USER_ID.slice(0, -1)],
    ['a uuid with a non-hex character', `${USER_ID.slice(0, -1)}g`],
    ['SQL', "1' OR '1'='1"],
    ['an empty string', ''],
  ])('refuses %s', (_label, id) => {
    expect(failedFields(userIdParamsSchema, { id })).toEqual(['id']);
    expect(messages(userIdParamsSchema, { id })).toEqual(['must be a valid user id']);
  });
});

describe('listUsersQuerySchema', () => {
  describe('accepts', () => {
    it('no query at all, giving the first page of pending requests', () => {
      expect(listUsersQuerySchema.parse({})).toEqual({ status: 'pending', limit: LIST_LIMIT_DEFAULT, offset: 0 });
    });

    it.each(['pending', 'active', 'suspended', 'rejected'])('the status %s', (status) => {
      expect(listUsersQuerySchema.parse({ status }).status).toBe(status);
    });

    it('limit and offset as query strings, turned into numbers', () => {
      expect(listUsersQuerySchema.parse({ limit: '50', offset: '100' })).toMatchObject({ limit: 50, offset: 100 });
    });

    it.each([
      ['the smallest limit', { limit: '1' }],
      ['the largest limit', { limit: String(LIST_LIMIT_MAX) }],
      ['offset 0', { offset: '0' }],
      ['the largest offset', { offset: String(LIST_OFFSET_MAX) }],
    ])('%s', (_label, query) => {
      expect(listUsersQuerySchema.safeParse(query).success).toBe(true);
    });
  });

  describe('refuses', () => {
    it.each([
      ['an unknown status', { status: 'deleted' }, 'status', 'must be pending, active, suspended or rejected'],
      ['a status in capitals', { status: 'PENDING' }, 'status', 'must be pending, active, suspended or rejected'],
      ['limit 0', { limit: '0' }, 'limit', 'must be at least 1'],
      ['a limit over the cap', { limit: String(LIST_LIMIT_MAX + 1) }, 'limit', `must be at most ${LIST_LIMIT_MAX}`],
      ['an offset over the cap', { offset: String(LIST_OFFSET_MAX + 1) }, 'offset', `must be at most ${LIST_OFFSET_MAX}`],
      ['a negative offset', { offset: '-1' }, 'offset', 'must be a whole number'],
      ['a decimal limit', { limit: '1.5' }, 'limit', 'must be a whole number'],
      ['an empty limit', { limit: '' }, 'limit', 'must be a whole number'],
      // Number() would read these as 16, 100 and 5; only plain digits are allowed.
      ['a hex limit', { limit: '0x10' }, 'limit', 'must be a whole number'],
      ['an exponent limit', { limit: '1e2' }, 'limit', 'must be a whole number'],
      ['a limit with spaces', { limit: ' 5 ' }, 'limit', 'must be a whole number'],
    ])('%s', (_label, query, field, message) => {
      expect(failedFields(listUsersQuerySchema, query)).toEqual([field]);
      expect(messages(listUsersQuerySchema, query)).toEqual([message]);
    });

    it('a repeated parameter, which arrives as an array', () => {
      expect(failedFields(listUsersQuerySchema, { limit: ['1', '2'] })).toEqual(['limit']);
    });

    it.each([
      ['role', { role: 'admin' }],
      ['sort', { sort: 'password_hash' }],
      ['page', { page: '2' }],
    ])('the unknown parameter %s', (field, query) => {
      expect(failedFields(listUsersQuerySchema, query)).toEqual([field]);
    });
  });
});

describe('reasonBodySchema', () => {
  describe('accepts', () => {
    it('and trims a reason', () => {
      expect(reasonBodySchema.parse({ reason: '  Licence number could not be verified ' })).toEqual({
        reason: 'Licence number could not be verified',
      });
    });

    it.each([
      [`${REASON_MIN_LENGTH} characters`, 'a'.repeat(REASON_MIN_LENGTH)],
      [`${REASON_MAX_LENGTH} characters`, 'a'.repeat(REASON_MAX_LENGTH)],
      ['several lines', 'Lost device reported.\nNew phone expected next week.'],
      // The limits apply after trimming, so spaces around a full-length reason are fine.
      [`${REASON_MAX_LENGTH} characters with spaces around`, ` ${'a'.repeat(REASON_MAX_LENGTH)} `],
    ])('%s', (_label, reason) => {
      expect(reasonBodySchema.safeParse({ reason }).success).toBe(true);
    });
  });

  describe('refuses', () => {
    it.each([
      ['an empty reason', '', `must be at least ${REASON_MIN_LENGTH} characters`],
      ['a blank reason', '      ', `must be at least ${REASON_MIN_LENGTH} characters`],
      ['a reason too short once trimmed', '  ab  ', `must be at least ${REASON_MIN_LENGTH} characters`],
      ['a reason over the limit', 'a'.repeat(REASON_MAX_LENGTH + 1), `must be at most ${REASON_MAX_LENGTH} characters`],
    ])('%s', (_label, reason, message) => {
      expect(failedFields(reasonBodySchema, { reason })).toEqual(['reason']);
      expect(messages(reasonBodySchema, { reason })).toEqual([message]);
    });

    it.each([
      ['a reason that is not text', { reason: 12345 }, ['reason']],
      ['a request without a reason', {}, ['reason']],
      ['no body at all', undefined, ['']],
    ])('%s', (_label, body, fields) => {
      expect(failedFields(reasonBodySchema, body)).toEqual(fields);
    });

    it.each([
      ['status', { status: 'active' }],
      ['role', { role: 'admin' }],
      ['approvedBy', { approvedBy: USER_ID }],
    ])('the extra field %s', (field, extra) => {
      expect(failedFields(reasonBodySchema, { reason: 'Under investigation', ...extra })).toEqual([field]);
    });
  });
});

describe('emptyBodySchema', () => {
  it('accepts no body at all, as Express 5 gives for a POST without one', () => {
    expect(emptyBodySchema.safeParse(undefined).success).toBe(true);
  });

  it('accepts an empty object', () => {
    expect(emptyBodySchema.safeParse({}).success).toBe(true);
  });

  it.each([
    ['reason', { reason: 'Welcome back' }],
    ['status', { status: 'active' }],
    ['role', { role: 'officer' }],
  ])('refuses the field %s', (field, body) => {
    expect(failedFields(emptyBodySchema, body)).toEqual([field]);
  });

  it('refuses a body that is not an object', () => {
    expect(emptyBodySchema.safeParse(['approve']).success).toBe(false);
  });
});
