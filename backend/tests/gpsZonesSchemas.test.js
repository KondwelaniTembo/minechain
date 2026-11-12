import { describe, it, expect } from 'vitest';
import {
  zoneIdParamsSchema,
  createZoneBodySchema,
  renameZoneBodySchema,
  listZonesQuerySchema,
  ZONE_NAME_MAX_LENGTH,
} from '../src/schemas/gpsZones.js';

const ZONE_ID = '3f2b8c1e-7a4d-4e5f-9b6a-1c2d3e4f5a6b';

// A small triangle near Lusaka, as [lat, lng] corners. Fake, not a real licence boundary.
const TRIANGLE = [
  [-15.39, 28.32],
  [-15.4, 28.33],
  [-15.41, 28.31],
];

// Each issue as "path: message", so a test also shows which field was refused.
const issues = (schema, value) => {
  const result = schema.safeParse(value);
  return result.success ? [] : result.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`);
};

describe('zoneIdParamsSchema', () => {
  it('accepts a uuid', () => {
    expect(zoneIdParamsSchema.parse({ id: ZONE_ID })).toEqual({ id: ZONE_ID });
  });

  it.each([
    ['not a uuid', { id: 'zone-1' }, 'id: must be a valid zone id'],
    ['an extra parameter', { id: ZONE_ID, other: 'x' }, ': Unrecognized key: "other"'],
  ])('refuses %s', (_label, value, issue) => {
    expect(issues(zoneIdParamsSchema, value)).toEqual([issue]);
  });
});

describe('createZoneBodySchema', () => {
  it('accepts a name and boundary, trimming the name, with no licence number', () => {
    expect(createZoneBodySchema.parse({ name: '  Kasempa North  ', boundary: TRIANGLE })).toEqual({
      name: 'Kasempa North',
      boundary: TRIANGLE,
    });
  });

  it('accepts a licence number, trimmed', () => {
    const body = createZoneBodySchema.parse({ name: 'Kasempa North', licenceNumber: ' DEMO-LML-0001 ', boundary: TRIANGLE });

    expect(body.licenceNumber).toBe('DEMO-LML-0001');
  });

  it(`accepts a name of exactly ${ZONE_NAME_MAX_LENGTH} characters`, () => {
    expect(createZoneBodySchema.safeParse({ name: 'K'.repeat(ZONE_NAME_MAX_LENGTH), boundary: TRIANGLE }).success).toBe(true);
  });

  it.each([
    ['no name', { boundary: TRIANGLE }, 'name: Invalid input: expected string, received undefined'],
    ['a name of 2 characters after trimming', { name: '  ab ', boundary: TRIANGLE }, 'name: must be at least 3 characters'],
    [
      `a name over ${ZONE_NAME_MAX_LENGTH} characters`,
      { name: 'K'.repeat(ZONE_NAME_MAX_LENGTH + 1), boundary: TRIANGLE },
      `name: must be at most ${ZONE_NAME_MAX_LENGTH} characters`,
    ],
    ['a blank licence number', { name: 'Kasempa North', licenceNumber: '   ', boundary: TRIANGLE }, 'licenceNumber: must not be blank'],
    [
      'a licence number over 50 characters',
      { name: 'Kasempa North', licenceNumber: 'L'.repeat(51), boundary: TRIANGLE },
      'licenceNumber: must be at most 50 characters',
    ],
    ['no boundary', { name: 'Kasempa North' }, 'boundary: Invalid input: expected array, received undefined'],
    [
      'a closed ring, pointing into the boundary',
      { name: 'Kasempa North', boundary: [...TRIANGLE, TRIANGLE[0]] },
      'boundary.3: repeats the first corner; list each corner once, without repeating the first corner at the end',
    ],
    ['a status sent with it', { name: 'Kasempa North', boundary: TRIANGLE, status: 'inactive' }, ': Unrecognized key: "status"'],
    ['a createdBy sent with it', { name: 'Kasempa North', boundary: TRIANGLE, createdBy: ZONE_ID }, ': Unrecognized key: "createdBy"'],
  ])('refuses %s', (_label, value, issue) => {
    expect(issues(createZoneBodySchema, value)).toEqual([issue]);
  });
});

describe('renameZoneBodySchema', () => {
  it('accepts a name, trimmed', () => {
    expect(renameZoneBodySchema.parse({ name: ' Kasempa North (until Nov 2026) ' })).toEqual({
      name: 'Kasempa North (until Nov 2026)',
    });
  });

  it.each([
    ['no body field at all', {}, 'name: Invalid input: expected string, received undefined'],
    ['a boundary, which can never change', { name: 'Kasempa North', boundary: TRIANGLE }, ': Unrecognized key: "boundary"'],
    ['a licence number, which can never change', { name: 'Kasempa North', licenceNumber: 'X-1' }, ': Unrecognized key: "licenceNumber"'],
  ])('refuses %s', (_label, value, issue) => {
    expect(issues(renameZoneBodySchema, value)).toEqual([issue]);
  });
});

describe('listZonesQuerySchema', () => {
  it('lists the first page of active zones when the query is empty', () => {
    expect(listZonesQuerySchema.parse({})).toEqual({ status: 'active', limit: 20, offset: 0 });
  });

  it('accepts inactive and paging values', () => {
    expect(listZonesQuerySchema.parse({ status: 'inactive', limit: '100', offset: '40' })).toEqual({
      status: 'inactive',
      limit: 100,
      offset: 40,
    });
  });

  it.each([
    ['a status that does not exist', { status: 'deleted' }, 'status: must be active or inactive'],
    ['a limit of 0', { limit: '0' }, 'limit: must be at least 1'],
    ['a limit over 100', { limit: '101' }, 'limit: must be at most 100'],
    ['a limit in exponent form', { limit: '1e2' }, 'limit: must be a whole number'],
    ['an offset over 10,000', { offset: '10001' }, 'offset: must be at most 10000'],
    ['an unknown parameter', { name: 'Kasempa' }, ': Unrecognized key: "name"'],
  ])('refuses %s', (_label, value, issue) => {
    expect(issues(listZonesQuerySchema, value)).toEqual([issue]);
  });
});
