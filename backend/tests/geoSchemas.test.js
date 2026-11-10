import { describe, it, expect } from 'vitest';
import {
  decimalPlaces,
  latitudeSchema,
  longitudeSchema,
  cornerSchema,
  zoneBoundarySchema,
  MAX_ZONE_CORNERS,
} from '../src/schemas/geo.js';
import { ZCAS_CAMPUS_BOUNDARY } from '../src/seed/seedData.js';

// A small triangle near Lusaka, as [lat, lng] corners. Fake, not a real licence boundary.
const TRIANGLE = [
  [-15.39, 28.32],
  [-15.4, 28.33],
  [-15.41, 28.31],
];

const messages = (schema, value) => {
  const result = schema.safeParse(value);
  return result.success ? [] : result.error.issues.map((i) => i.message);
};

describe('decimalPlaces', () => {
  it.each([
    [15.123456, 6],
    [15.1234567, 7],
    [-15.4, 1],
    [0, 0],
    [-0, 0],
    [90, 0],
    [0.000001, 6],
    // Below 1e-6, JavaScript prints exponent form, so the exponent must be counted.
    [1e-7, 7],
    [1.5e-7, 8],
    [-2.5e-8, 9],
  ])('%s has %i decimal places', (value, expected) => {
    expect(decimalPlaces(value)).toBe(expected);
  });

  it('is not fooled by floating point, where x * 1e6 misses a whole number', () => {
    // The trap an arithmetic check falls into: 1.000001 has 6 places, but in floating point
    // 1.000001 * 1e6 is 1000000.9999999999, not 1000001.
    expect(Number.isInteger(1.000001 * 1e6)).toBe(false);
    expect(decimalPlaces(1.000001)).toBe(6);
  });

  it('counts the real digits of an arithmetic result, such as 0.1 + 0.2', () => {
    // 0.1 + 0.2 is 0.30000000000000004 in floating point, so it must not pass as 0.3.
    expect(decimalPlaces(0.1 + 0.2)).toBe(17);
  });
});

describe('latitudeSchema', () => {
  describe('accepts', () => {
    it.each([15.123456, -15.4, 0, 90, -90, 89.999999, -89.999999, 1.000001])('%s', (value) => {
      expect(latitudeSchema.safeParse(value).success).toBe(true);
    });
  });

  describe('refuses', () => {
    it.each([
      ['7 decimal places', 15.1234567, 'must have at most 6 decimal places'],
      ['a tiny value in exponent form', 1e-7, 'must have at most 6 decimal places'],
      ['just above 90', 90.000001, 'must be between -90 and 90'],
      ['just below -90', -90.000001, 'must be between -90 and 90'],
      ['a longitude-sized value', 120, 'must be between -90 and 90'],
    ])('%s', (_label, value, message) => {
      expect(messages(latitudeSchema, value)).toContain(message);
    });

    it.each([
      ['a numeric string', '15.4'],
      ['NaN', Number.NaN],
      ['Infinity', Number.POSITIVE_INFINITY],
      ['null', null],
    ])('%s', (_label, value) => {
      expect(latitudeSchema.safeParse(value).success).toBe(false);
    });
  });
});

describe('longitudeSchema', () => {
  it.each([180, -180, 28.287123, 0])('accepts %s', (value) => {
    expect(longitudeSchema.safeParse(value).success).toBe(true);
  });

  it.each([
    [180.000001, 'must be between -180 and 180'],
    [-180.000001, 'must be between -180 and 180'],
    [28.2871234, 'must have at most 6 decimal places'],
  ])('refuses %s', (value, message) => {
    expect(messages(longitudeSchema, value)).toContain(message);
  });
});

describe('cornerSchema', () => {
  it('accepts a [lat, lng] pair', () => {
    expect(cornerSchema.parse([-15.39, 28.32])).toEqual([-15.39, 28.32]);
  });

  it.each([
    ['one number', [-15.39]],
    ['three numbers (an altitude added)', [-15.39, 28.32, 1200]],
    ['an object instead of a pair', { lat: -15.39, lng: 28.32 }],
    ['a latitude out of range', [-95, 28.32]],
  ])('refuses %s', (_label, value) => {
    expect(cornerSchema.safeParse(value).success).toBe(false);
  });

  it('points at the bad half of the pair', () => {
    const result = cornerSchema.safeParse([-15.39, 28.3212345]);

    expect(result.error.issues[0].path).toEqual([1]);
  });
});

describe('zoneBoundarySchema', () => {
  it('accepts a triangle', () => {
    expect(zoneBoundarySchema.parse(TRIANGLE)).toEqual(TRIANGLE);
  });

  it(`accepts ${MAX_ZONE_CORNERS} corners`, () => {
    // Corners round a circle about 1 km across, so they are all different and enclose an
    // area (the shape rules refuse repeated corners). Rounded to the 6-decimal limit.
    const round6 = (x) => Number(x.toFixed(6));
    const corners = Array.from({ length: MAX_ZONE_CORNERS }, (_, i) => {
      const angle = (2 * Math.PI * i) / MAX_ZONE_CORNERS;
      return [round6(-15.4 + 0.01 * Math.sin(angle)), round6(28.3 + 0.01 * Math.cos(angle))];
    });

    expect(zoneBoundarySchema.safeParse(corners).success).toBe(true);
  });

  it('accepts the seeded ZCAS campus boundary', () => {
    expect(zoneBoundarySchema.safeParse(ZCAS_CAMPUS_BOUNDARY).success).toBe(true);
  });

  it.each([
    ['no corners', [], 'must have at least 3 corners'],
    ['two corners', TRIANGLE.slice(0, 2), 'must have at least 3 corners'],
    [
      `${MAX_ZONE_CORNERS + 1} corners`,
      Array.from({ length: MAX_ZONE_CORNERS + 1 }, () => [-15.39, 28.32]),
      `must have at most ${MAX_ZONE_CORNERS} corners`,
    ],
  ])('refuses %s', (_label, value, message) => {
    expect(messages(zoneBoundarySchema, value)).toContain(message);
  });

  it('refuses something that is not an array', () => {
    expect(zoneBoundarySchema.safeParse({ type: 'Polygon' }).success).toBe(false);
  });

  it('points at the corner with too many decimal places', () => {
    const boundary = [TRIANGLE[0], [-15.4000001, 28.33], TRIANGLE[2]];
    const result = zoneBoundarySchema.safeParse(boundary);

    expect(result.error.issues).toHaveLength(1);
    expect(result.error.issues[0].path).toEqual([1, 0]);
    expect(result.error.issues[0].message).toBe('must have at most 6 decimal places');
  });

  describe('shape rules (zoneShape.js)', () => {
    it('refuses a closed ring, pointing at the repeated corner', () => {
      const result = zoneBoundarySchema.safeParse([...TRIANGLE, TRIANGLE[0]]);

      expect(result.error.issues).toHaveLength(1);
      expect(result.error.issues[0].path).toEqual([3]);
      expect(result.error.issues[0].message).toContain('without repeating the first corner at the end');
    });

    it('refuses [lng, lat] corners, saying latitude comes first', () => {
      const swapped = TRIANGLE.map(([lat, lng]) => [lng, lat]);

      expect(messages(zoneBoundarySchema, swapped)).toEqual([expect.stringContaining('[latitude, longitude], latitude first')]);
    });

    it('refuses a boundary as a whole with an empty path, such as corners on one line', () => {
      const line = [
        [-15.4, 28.3],
        [-15.401, 28.301],
        [-15.402, 28.302],
      ];
      const result = zoneBoundarySchema.safeParse(line);

      expect(result.error.issues).toEqual([expect.objectContaining({ path: [], message: expect.stringContaining('must enclose at least') })]);
    });

    it('does not run while a corner is invalid, so the bad corner is reported alone', () => {
      // Closed AND a corner with 7 decimals: only the corner is reported. The shape rules
      // run once the corners are fixed.
      const boundary = [TRIANGLE[0], [-15.4000001, 28.33], TRIANGLE[2], TRIANGLE[0]];

      expect(messages(zoneBoundarySchema, boundary)).toEqual(['must have at most 6 decimal places']);
    });

    it('does not run when there are too few corners', () => {
      expect(messages(zoneBoundarySchema, [TRIANGLE[0], TRIANGLE[0]])).toEqual(['must have at least 3 corners']);
    });
  });
});
