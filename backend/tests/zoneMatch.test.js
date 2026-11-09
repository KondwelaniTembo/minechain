import { describe, it, expect } from 'vitest';
import {
  matchZone,
  pointInPolygon,
  distanceToBoundaryMetres,
  pointFromText,
  ZONE_TOLERANCE_METRES,
  EARTH_RADIUS_METRES,
} from '../src/services/zoneMatch.js';
import { ZCAS_CAMPUS_BOUNDARY } from '../src/seed/seedData.js';

// Test points are placed with the spherical "destination point" formula: start here, go d
// metres on this bearing. It is independent of the module's flat projection, so a distance
// the module measures back is a real check, not the module agreeing with itself.
const toRad = (deg) => (deg * Math.PI) / 180;
const toDeg = (rad) => (rad * 180) / Math.PI;
function destination([lat, lng], bearingDeg, metres) {
  const delta = metres / EARTH_RADIUS_METRES;
  const theta = toRad(bearingDeg);
  const phi1 = toRad(lat);
  const phi2 = Math.asin(Math.sin(phi1) * Math.cos(delta) + Math.cos(phi1) * Math.sin(delta) * Math.cos(theta));
  const lambda2 =
    toRad(lng) + Math.atan2(Math.sin(theta) * Math.sin(delta) * Math.cos(phi1), Math.cos(delta) - Math.sin(phi1) * Math.sin(phi2));
  return [toDeg(phi2), toDeg(lambda2)];
}
const NORTH = 0;
const EAST = 90;
const SOUTH = 180;
const asPoint = ([lat, lng]) => ({ lat, lng });

// A square about 200 m across near Lusaka, built from its centre with the same formula.
const CENTRE = [-15.42, 28.29];
const HALF = 100;
function square(centre = CENTRE, half = HALF) {
  const north = destination(centre, NORTH, half)[0];
  const south = destination(centre, SOUTH, half)[0];
  const east = destination(centre, EAST, half)[1];
  const west = destination(centre, 270, half)[1];
  return [
    [south, west],
    [south, east],
    [north, east],
    [north, west],
  ];
}
const SQUARE = square();
const NORTH_EDGE_MIDDLE = [SQUARE[2][0], CENTRE[1]];
const zone = (id, name, boundary = SQUARE) => ({ id, name, boundary });

describe('pointInPolygon', () => {
  it('finds the centre of a square inside it', () => {
    expect(pointInPolygon(asPoint(CENTRE), SQUARE)).toBe(true);
  });

  it('finds a point well outside it outside', () => {
    expect(pointInPolygon(asPoint(destination(CENTRE, NORTH, 500)), SQUARE)).toBe(false);
  });

  it('counts a point on an edge, and on a corner, as inside', () => {
    expect(pointInPolygon(asPoint(NORTH_EDGE_MIDDLE), SQUARE)).toBe(true);
    expect(pointInPolygon(asPoint(SQUARE[0]), SQUARE)).toBe(true);
    expect(pointInPolygon(asPoint(SQUARE[2]), SQUARE)).toBe(true);
  });

  it('gives the same answers whether or not the boundary repeats its first corner', () => {
    const closed = [...SQUARE, SQUARE[0]];
    for (const p of [CENTRE, destination(CENTRE, NORTH, 500), NORTH_EDGE_MIDDLE]) {
      expect(pointInPolygon(asPoint(p), closed)).toBe(pointInPolygon(asPoint(p), SQUARE));
    }
  });

  describe('a concave polygon (a C open to the east)', () => {
    // Units of 0.001 degree from a base corner: an outer 3 x 3 box with a 2 x 1 notch cut
    // into its east side. Corners as [lat, lng] = [base + y, base + x].
    const BASE = [-15.43, 28.3];
    const at = (x, y) => [BASE[0] + y * 0.001, BASE[1] + x * 0.001];
    const C_SHAPE = [at(0, 0), at(3, 0), at(3, 1), at(1, 1), at(1, 2), at(3, 2), at(3, 3), at(0, 3)];

    it('puts a point in the notch outside', () => {
      expect(pointInPolygon(asPoint(at(2, 1.5)), C_SHAPE)).toBe(false);
    });

    it('puts points in the arms inside', () => {
      expect(pointInPolygon(asPoint(at(0.5, 1.5)), C_SHAPE)).toBe(true);
      expect(pointInPolygon(asPoint(at(2, 0.5)), C_SHAPE)).toBe(true);
      expect(pointInPolygon(asPoint(at(2, 2.5)), C_SHAPE)).toBe(true);
    });

    it('measures the notch point to its nearest edge (half a unit of latitude away)', () => {
      const halfUnitMetres = toRad(0.0005) * EARTH_RADIUS_METRES; // about 55.6 m
      expect(distanceToBoundaryMetres(asPoint(at(2, 1.5)), C_SHAPE)).toBeCloseTo(halfUnitMetres, 0);
    });
  });
});

describe('distanceToBoundaryMetres', () => {
  // The flat projection against the sphere, over 100 m: the error must stay within 1 m.
  it.each([
    ['north of the north edge', NORTH_EDGE_MIDDLE, NORTH],
    ['east of the east edge', [CENTRE[0], SQUARE[1][1]], EAST],
    ['diagonally out from a corner', SQUARE[2], 45],
  ])('is within 1 m for a point placed exactly 100 m %s', (_label, from, bearing) => {
    const point = asPoint(destination(from, bearing, 100));

    expect(Math.abs(distanceToBoundaryMetres(point, SQUARE) - 100)).toBeLessThanOrEqual(1);
  });

  it('measures an inside point to its nearest edge too', () => {
    expect(Math.abs(distanceToBoundaryMetres(asPoint(CENTRE), SQUARE) - HALF)).toBeLessThanOrEqual(1);
  });

  it('is 0 on an edge', () => {
    expect(distanceToBoundaryMetres(asPoint(NORTH_EDGE_MIDDLE), SQUARE)).toBeLessThan(1e-6);
  });
});

describe('matchZone', () => {
  it('matches a point inside a zone, at distance 0', () => {
    expect(matchZone(asPoint(CENTRE), [zone('z1', 'Square')])).toEqual({
      zoneId: 'z1',
      zoneName: 'Square',
      inside: true,
      distanceMetres: 0,
      nearestZoneId: 'z1',
      nearestZoneName: 'Square',
    });
  });

  it('uses a 25 m tolerance by default', () => {
    expect(ZONE_TOLERANCE_METRES).toBe(25);
  });

  it('matches a point 24 m outside the edge, saying it is not inside', () => {
    const result = matchZone(asPoint(destination(NORTH_EDGE_MIDDLE, NORTH, 24)), [zone('z1', 'Square')]);

    expect(result).toMatchObject({ zoneId: 'z1', inside: false });
    expect(Math.abs(result.distanceMetres - 24)).toBeLessThanOrEqual(1);
  });

  it('does not match a point 26 m outside, but still names the nearest zone and its distance', () => {
    const result = matchZone(asPoint(destination(NORTH_EDGE_MIDDLE, NORTH, 26)), [zone('z1', 'Square')]);

    expect(result).toMatchObject({ zoneId: null, zoneName: null, inside: false, nearestZoneId: 'z1', nearestZoneName: 'Square' });
    expect(Math.abs(result.distanceMetres - 26)).toBeLessThanOrEqual(1);
  });

  it('accepts another tolerance, 0 meaning the polygon only', () => {
    const point = asPoint(destination(NORTH_EDGE_MIDDLE, NORTH, 1));

    expect(matchZone(point, [zone('z1', 'Square')], { toleranceMetres: 0 }).zoneId).toBeNull();
    expect(matchZone(point, [zone('z1', 'Square')]).zoneId).toBe('z1');
  });

  it('answers "no zone" with nothing nearest when there are no zones at all', () => {
    expect(matchZone(asPoint(CENTRE), [])).toEqual({
      zoneId: null,
      zoneName: null,
      inside: false,
      distanceMetres: null,
      nearestZoneId: null,
      nearestZoneName: null,
    });
  });

  it('returns a frozen result', () => {
    expect(Object.isFrozen(matchZone(asPoint(CENTRE), [zone('z1', 'Square')]))).toBe(true);
  });

  describe('choosing between zones, the same way every time', () => {
    it('picks by name when the point is inside two zones, whatever their order', () => {
      const zones = [zone('b', 'Beta'), zone('a', 'Alpha')];

      expect(matchZone(asPoint(CENTRE), zones).zoneId).toBe('a');
      expect(matchZone(asPoint(CENTRE), [...zones].reverse()).zoneId).toBe('a');
    });

    it('prefers a zone the point is inside over one it is only near, whatever the names', () => {
      const point = destination(NORTH_EDGE_MIDDLE, NORTH, 10); // 10 m outside the first square
      const containing = square(point, 50);
      const result = matchZone(asPoint(point), [zone('near', 'Alpha'), zone('in', 'Zulu', containing)]);

      expect(result).toMatchObject({ zoneId: 'in', inside: true });
    });

    it('picks the nearer of two zones the point is only near', () => {
      const point = destination(NORTH_EDGE_MIDDLE, NORTH, 20); // 20 m outside the first square
      const otherCentre = destination(point, NORTH, 50 + 10); // a square whose south edge is 10 m away
      const result = matchZone(asPoint(point), [zone('far', 'Alpha'), zone('close', 'Zulu', square(otherCentre, 50))]);

      expect(result.zoneId).toBe('close');
      expect(Math.abs(result.distanceMetres - 10)).toBeLessThanOrEqual(1);
    });
  });

  describe('the real campus zone from the seed data', () => {
    const CAMPUS = [zone('campus', 'ZCAS Campus (demo)', ZCAS_CAMPUS_BOUNDARY)];
    // The first corner is the zone's southernmost point, and both of its edges run north of
    // it, so a point due south of it is nearest to the corner itself.
    const SOUTH_CORNER = ZCAS_CAMPUS_BOUNDARY[0];

    it('matches a point in the middle of campus as inside', () => {
      expect(matchZone(asPoint([-15.4189, 28.288]), CAMPUS)).toMatchObject({ zoneId: 'campus', inside: true });
    });

    it('matches a reading about 10 m outside (ordinary GPS error) within the tolerance', () => {
      const result = matchZone(asPoint(destination(SOUTH_CORNER, SOUTH, 10)), CAMPUS);

      expect(result).toMatchObject({ zoneId: 'campus', inside: false });
      expect(Math.abs(result.distanceMetres - 10)).toBeLessThanOrEqual(0.5);
    });

    it('does not match a point 40 m outside', () => {
      const result = matchZone(asPoint(destination(SOUTH_CORNER, SOUTH, 40)), CAMPUS);

      expect(result).toMatchObject({ zoneId: null, nearestZoneId: 'campus' });
      expect(Math.abs(result.distanceMetres - 40)).toBeLessThanOrEqual(0.5);
    });
  });
});

describe('input', () => {
  it('reads the signed payload\'s coordinate text', () => {
    expect(pointFromText('-15.419751', '28.287496')).toEqual({ lat: -15.419751, lng: 28.287496 });
  });

  it.each([
    ['text that is not a number', () => pointFromText('abc', '28.28')],
    ['a missing point', () => matchZone(undefined, [])],
    ['NaN', () => matchZone({ lat: Number.NaN, lng: 1 }, [])],
    ['Infinity', () => distanceToBoundaryMetres({ lat: 1, lng: Infinity }, SQUARE)],
    ['a negative tolerance', () => matchZone(asPoint(CENTRE), [], { toleranceMetres: -1 })],
  ])('refuses %s', (_label, fn) => {
    expect(fn).toThrow(TypeError);
  });
});
