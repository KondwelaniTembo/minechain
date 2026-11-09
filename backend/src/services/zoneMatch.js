// Which licensed GPS zone a point falls in (FR-08's GPS zone rule, FR-11's zones).
//
// Zones are polygons of [lat, lng] corners (D4; note the order, not GeoJSON's [lng, lat]).
// A point counts as in a zone if it is inside the polygon, on its edge, or within a
// tolerance of the edge, because phone GPS is typically 5-10 m off and worse near
// buildings.
//
// Floats are used on purpose here, unlike for weights. Nothing computed in this module is
// signed or hashed: the stored coordinates stay the exact signed text, and what is kept
// from here is only which zone matched and, in an alert's details, a distance rounded to
// whole metres. Over a few hundred metres the method below is accurate to well under a
// metre, far finer than the GPS reading itself.
//
// Pure: no database. The caller passes the active zones.

// A point this close to a zone's edge counts as inside it. The demo campus zone is about
// 160 x 340 m, so 25 m is about 15% of its short side: enough for GPS error, not enough to
// accept a site down the road.
export const ZONE_TOLERANCE_METRES = 25;

// The mean Earth radius (IUGG). A sphere is plenty at this scale.
export const EARTH_RADIUS_METRES = 6_371_000;

const METRES_PER_DEGREE = (EARTH_RADIUS_METRES * Math.PI) / 180;

// Below this a point is on the edge. Far below anything GPS can tell apart; it only absorbs
// floating-point rounding when a point is exactly on a corner or edge.
const ON_EDGE_METRES = 1e-6;

function assertPoint(point) {
  if (!point || !Number.isFinite(point.lat) || !Number.isFinite(point.lng)) {
    throw new TypeError('point must be { lat, lng } with finite numbers');
  }
}

// The signed payload carries coordinates as text ("-15.419751"). Number() is fine here:
// see the note at the top.
export function pointFromText(latitude, longitude) {
  const point = { lat: Number(latitude), lng: Number(longitude) };
  assertPoint(point);
  return point;
}

// Local equirectangular projection centred on the point: metres east (x) and north (y) of
// it. One degree of latitude is the same length everywhere; one degree of longitude
// shrinks with cos(latitude), taken at the point. The point itself is at (0, 0).
function project(point, [lat, lng]) {
  // Normalised to -180..180, so a zone across the antimeridian is not 360 degrees away.
  const dLng = ((((lng - point.lng) % 360) + 540) % 360) - 180;
  return {
    x: dLng * Math.cos((point.lat * Math.PI) / 180) * METRES_PER_DEGREE,
    y: (lat - point.lat) * METRES_PER_DEGREE,
  };
}

// Distance from the origin to the segment a-b.
function distanceToSegment(a, b) {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const lengthSquared = dx * dx + dy * dy;
  // How far along a-b the closest point lies, clamped to the segment's ends.
  const t = lengthSquared === 0 ? 0 : Math.min(1, Math.max(0, -(a.x * dx + a.y * dy) / lengthSquared));
  return Math.hypot(a.x + t * dx, a.y + t * dy);
}

// Each edge of the polygon, closing it from the last corner back to the first. A boundary
// that repeats its first corner at the end just adds an edge of zero length.
function* edges(corners) {
  for (let i = 0; i < corners.length; i += 1) {
    yield [corners[i], corners[(i + 1) % corners.length]];
  }
}

// Metres from the point to the nearest edge of the polygon, whether the point is inside or
// outside it.
export function distanceToBoundaryMetres(point, boundary) {
  assertPoint(point);
  const corners = boundary.map((corner) => project(point, corner));
  let nearest = Infinity;
  for (const [a, b] of edges(corners)) nearest = Math.min(nearest, distanceToSegment(a, b));
  return nearest;
}

// Ray casting: a ray from the point crosses the polygon's edge an odd number of times if
// and only if the point is inside. Done on the projected corners, which gives the same
// answer as on raw degrees (the projection only stretches the axes) and keeps one set of
// coordinates. A point on an edge or corner counts as inside.
export function pointInPolygon(point, boundary) {
  if (distanceToBoundaryMetres(point, boundary) <= ON_EDGE_METRES) return true;
  const corners = boundary.map((corner) => project(point, corner));
  let inside = false;
  for (const [a, b] of edges(corners)) {
    // Does this edge cross the ray going east from the origin (y = 0, x > 0)? The strict and
    // non-strict comparisons count a corner on the ray exactly once.
    if (a.y > 0 !== b.y > 0) {
      const xAtRay = a.x + ((0 - a.y) * (b.x - a.x)) / (b.y - a.y);
      if (xAtRay > 0) inside = !inside;
    }
  }
  return inside;
}

// Orders candidate zones the same way every time: inside before near, then nearer, then by
// name, then by id (names are unique, so the id only matters for zones with no name check,
// such as in tests).
function compareCandidates(a, b) {
  if (a.inside !== b.inside) return a.inside ? -1 : 1;
  if (a.distanceMetres !== b.distanceMetres) return a.distanceMetres - b.distanceMetres;
  if (a.zone.name !== b.zone.name) return a.zone.name < b.zone.name ? -1 : 1;
  return a.zone.id < b.zone.id ? -1 : a.zone.id > b.zone.id ? 1 : 0;
}

// The zone a point belongs to, among the zones given (the caller passes only active ones).
//   zones: [{ id, name, boundary: [[lat, lng], ...] }]
// Returns, frozen:
//   zoneId, zoneName       the matched zone, or null when the point is in none
//   inside                 true if inside the polygon, false if only within the tolerance
//   distanceMetres         0 when inside; otherwise metres to the matched or nearest zone;
//                          null when there are no zones at all
//   nearestZoneId, nearestZoneName
//                          the closest zone, matched or not (for an alert's details)
export function matchZone(point, zones, { toleranceMetres = ZONE_TOLERANCE_METRES } = {}) {
  assertPoint(point);
  if (!Number.isFinite(toleranceMetres) || toleranceMetres < 0) {
    throw new TypeError('toleranceMetres must be a number of 0 or more');
  }

  const candidates = zones.map((zone) => {
    const inside = pointInPolygon(point, zone.boundary);
    return { zone, inside, distanceMetres: inside ? 0 : distanceToBoundaryMetres(point, zone.boundary) };
  });
  candidates.sort(compareCandidates);

  const nearest = candidates[0] ?? null;
  const matched = nearest && (nearest.inside || nearest.distanceMetres <= toleranceMetres) ? nearest : null;

  return Object.freeze({
    zoneId: matched?.zone.id ?? null,
    zoneName: matched?.zone.name ?? null,
    inside: matched?.inside ?? false,
    distanceMetres: nearest?.distanceMetres ?? null,
    nearestZoneId: nearest?.zone.id ?? null,
    nearestZoneName: nearest?.zone.name ?? null,
  });
}
