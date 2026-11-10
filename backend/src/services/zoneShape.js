// Shape checks for a licensed GPS zone's boundary (FR-11), beyond the per-corner rules in
// schemas/geo.js. They catch boundaries that are well-formed numbers but cannot be a real
// licence area: a repeated corner, corners on one line, a shape the size of a province, or
// corners pasted in GeoJSON's [lng, lat] order.
//
// Pure: no database, no Zod. Expects corners that already passed cornerSchema (pairs of
// in-range numbers); zoneBoundarySchema only calls this after those pass.
//
// Not checked (known limits): a boundary whose edges cross each other (a "bow-tie"),
// holes, zones made of several polygons, and zones that overlap each other.

import { project } from './zoneMatch.js';

// A 10 m x 10 m square. Real licence areas are far larger; this only refuses shapes that
// enclose almost nothing, such as corners all on one line.
export const MIN_ZONE_AREA_SQUARE_METRES = 100;

// The longest side a zone's bounding box may have, north-south or east-west. Large-scale
// licences can cover many square kilometres, so this is generous; it is here to catch a
// mistyped corner (a wrong digit can move a corner hundreds of kilometres) and pasted junk.
export const MAX_ZONE_SPAN_METRES = 50_000;

// A rough box around Zambia, with a margin of about 0.3 to 0.5 degrees on each side (the
// country runs from about -8.2 to -18.1 latitude and 22.0 to 33.7 longitude). It is not the
// border: a corner just outside Zambia but inside the box passes. Its real job is to catch
// [lng, lat] corners, the order GeoJSON and many map tools use. Swapped, a Lusaka corner
// reads as latitude 28, which is still a valid latitude, so only a check like this sees it.
// This ties zone validation to one country on purpose; the app is for Zambian mining.
export const ZAMBIA_BOUNDS = Object.freeze({
  minLat: -18.5,
  maxLat: -8.0,
  minLng: 21.5,
  maxLng: 34.0,
});

const MIN_DISTINCT_CORNERS = 3;

// Compared as numbers: two corners are the same only if both values are exactly equal.
// Corners have at most 6 decimals (geo.js), so equal text always gives equal numbers.
function sameCorner([latA, lngA], [latB, lngB]) {
  return latA === latB && lngA === lngB;
}

function insideZambia([lat, lng]) {
  return lat >= ZAMBIA_BOUNDS.minLat && lat <= ZAMBIA_BOUNDS.maxLat && lng >= ZAMBIA_BOUNDS.minLng && lng <= ZAMBIA_BOUNDS.maxLng;
}

// The corners in metres, on the same local projection zoneMatch.js uses, centred on the
// middle of the boundary's bounding box so no corner is far from the centre.
function projectedCorners(boundary) {
  const lats = boundary.map(([lat]) => lat);
  const lngs = boundary.map(([, lng]) => lng);
  const centre = {
    lat: (Math.min(...lats) + Math.max(...lats)) / 2,
    lng: (Math.min(...lngs) + Math.max(...lngs)) / 2,
  };
  return boundary.map((corner) => project(centre, corner));
}

// The shoelace formula: walk the corners in order and add up the cross products of
// neighbouring corners; half the total is the enclosed area. For example the square
// (0,0) (10,0) (10,10) (0,10) gives (0 + 100 + 100 + 0) / 2 = 100. Going the other way round
// gives -100, hence the absolute value. For a bow-tie the two halves cancel out, so a
// symmetrical one has an area near 0 and is refused here as a side effect.
export function areaSquareMetres(boundary) {
  const corners = projectedCorners(boundary);
  let twiceArea = 0;
  for (let i = 0; i < corners.length; i += 1) {
    const a = corners[i];
    const b = corners[(i + 1) % corners.length];
    twiceArea += a.x * b.y - b.x * a.y;
  }
  return Math.abs(twiceArea) / 2;
}

// The bounding box's east-west and north-south sides, in metres.
export function spanMetres(boundary) {
  const corners = projectedCorners(boundary);
  const xs = corners.map(({ x }) => x);
  const ys = corners.map(({ y }) => y);
  return {
    eastWest: Math.max(...xs) - Math.min(...xs),
    northSouth: Math.max(...ys) - Math.min(...ys),
  };
}

// Every problem with the boundary's shape, as { path, message }. path is relative to the
// boundary array: [2] means the third corner, [] the boundary as a whole. Returns [] when
// the shape is fine.
export function boundaryShapeProblems(boundary) {
  const problems = [];
  const last = boundary.length - 1;

  for (let i = 1; i <= last; i += 1) {
    if (sameCorner(boundary[i], boundary[i - 1])) {
      problems.push({ path: [i], message: 'repeats the corner before it; list each corner once' });
    }
  }
  // GeoJSON closes a ring by repeating the first corner at the end. The edge back to the
  // first corner is always implied here (zoneMatch.js), so one form is stored, not two.
  if (sameCorner(boundary[last], boundary[0])) {
    problems.push({
      path: [last],
      message: 'repeats the first corner; list each corner once, without repeating the first corner at the end',
    });
  }

  const distinct = new Set(boundary.map(([lat, lng]) => `${lat},${lng}`)).size;
  if (distinct < MIN_DISTINCT_CORNERS) {
    problems.push({ path: [], message: `must have at least ${MIN_DISTINCT_CORNERS} different corners` });
  }

  // Only the first such corner is reported: when the order is swapped, every corner is
  // outside, and one clear message is more use than a hundred copies.
  const outside = boundary.findIndex((corner) => !insideZambia(corner));
  if (outside !== -1) {
    problems.push({
      path: [outside],
      message:
        'is outside Zambia; each corner must be [latitude, longitude], latitude first ' +
        '(in Zambia, latitude is about -8 to -18 and longitude about 22 to 34)',
    });
  }

  // With fewer than 3 different corners there is no shape to measure; the message above
  // already says what is wrong.
  if (distinct >= MIN_DISTINCT_CORNERS) {
    if (areaSquareMetres(boundary) < MIN_ZONE_AREA_SQUARE_METRES) {
      problems.push({
        path: [],
        message: `must enclose at least ${MIN_ZONE_AREA_SQUARE_METRES} square metres; check that the corners are not all on one line`,
      });
    }
    const { eastWest, northSouth } = spanMetres(boundary);
    if (eastWest > MAX_ZONE_SPAN_METRES || northSouth > MAX_ZONE_SPAN_METRES) {
      problems.push({
        path: [],
        message: `must fit within ${MAX_ZONE_SPAN_METRES / 1000} km from north to south and from east to west`,
      });
    }
  }

  return problems;
}
