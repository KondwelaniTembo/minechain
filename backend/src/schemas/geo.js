import { z } from 'zod';
import { boundaryShapeProblems } from '../services/zoneShape.js';

// Six decimal places is about 11 cm, finer than phone GPS. transactions stores
// numeric(9,6), and PostgreSQL silently rounds extra places, so a stored point would differ
// from the signed one and verification would fail. Extra places are refused, not rounded.
export const MAX_COORDINATE_DECIMALS = 6;

// A zone check runs point-in-polygon for every step, so the corner count is capped. 100 is
// far more than any licence boundary needs, and keeps one boundary small.
export const MAX_ZONE_CORNERS = 100;

// Counts decimal places from the number's text, not with arithmetic such as
// Number.isInteger(x * 1e6). Floating point cannot hold most decimals exactly: 0.1 is
// really 0.1000000000000000055..., and multiplying it by a power of ten can land just off a
// whole number, so an arithmetic check needs a tolerance, and any tolerance is a guess.
// String(x) is exact instead: JavaScript prints the shortest decimal that reads back as the
// same number, so 15.123456 prints as "15.123456", the digits the phone sent. pg also turns
// a number into a query value with String(x), so this checks the exact text PostgreSQL gets.
// Below 1e-6, JavaScript switches to exponent form ("1.5e-7"); the exponent is added on.
export function decimalPlaces(value) {
  const [mantissa, exponent = '0'] = String(value).toLowerCase().split('e');
  const fractionDigits = (mantissa.split('.')[1] ?? '').length;
  return Math.max(0, fractionDigits - Number(exponent));
}

// z.number() already refuses NaN and Infinity, and refuses strings such as "15.4": a
// coordinate must arrive as a JSON number, so it is never silently converted.
function coordinate(limit) {
  return z
    .number()
    .min(-limit, `must be between -${limit} and ${limit}`)
    .max(limit, `must be between -${limit} and ${limit}`)
    .refine(
      (value) => decimalPlaces(value) <= MAX_COORDINATE_DECIMALS,
      `must have at most ${MAX_COORDINATE_DECIMALS} decimal places`,
    );
}

export const latitudeSchema = coordinate(90);
export const longitudeSchema = coordinate(180);

// One corner, in [lat, lng] order, the same order as gps_zones.boundary (D4). GeoJSON and
// many map tools use [lng, lat], so a swapped corner near Lusaka (lat about -15, lng about
// 28) still passes here; zoneBoundarySchema's Zambia check catches it for a zone.
// A tuple refuses a third item, so [lat, lng, altitude] is not quietly accepted.
export const cornerSchema = z.tuple([latitudeSchema, longitudeSchema]);

// Two stages. First the same rules as the gps_zones CHECK constraints (at least 3 corners,
// each a pair of in-range numbers), plus the 6-decimal limit and the corner cap, checked
// here so a caller gets a clear message instead of a database error. Then the shape rules
// in zoneShape.js (no repeated corners, a real area, a sane size, inside Zambia).
// .pipe() runs the second stage only when the first found nothing wrong, so the shape
// checks never see a missing or out-of-range corner, and a bad corner is reported alone.
export const zoneBoundarySchema = z
  .array(cornerSchema)
  .min(3, 'must have at least 3 corners')
  .max(MAX_ZONE_CORNERS, `must have at most ${MAX_ZONE_CORNERS} corners`)
  .pipe(
    z.array(z.tuple([z.number(), z.number()])).superRefine((boundary, ctx) => {
      for (const { path, message } of boundaryShapeProblems(boundary)) {
        ctx.addIssue({ code: 'custom', path, message });
      }
    }),
  );
