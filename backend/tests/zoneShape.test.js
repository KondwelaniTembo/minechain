import { describe, it, expect } from 'vitest';
import {
  areaSquareMetres,
  spanMetres,
  boundaryShapeProblems,
  MIN_ZONE_AREA_SQUARE_METRES,
  MAX_ZONE_SPAN_METRES,
  ZAMBIA_BOUNDS,
} from '../src/services/zoneShape.js';
import { EARTH_RADIUS_METRES } from '../src/services/zoneMatch.js';
import { ZCAS_CAMPUS_BOUNDARY } from '../src/seed/seedData.js';

const METRES_PER_DEGREE = (EARTH_RADIUS_METRES * Math.PI) / 180;

// A square near Lusaka, 0.001 degrees on each side (about 111 m north-south and 107 m
// east-west), as [lat, lng] corners. Fake, not a real licence boundary.
const SQUARE = [
  [-15.4, 28.3],
  [-15.4, 28.301],
  [-15.401, 28.301],
  [-15.401, 28.3],
];
// Its sides in metres, worked out the way the module does: on the projection centred on
// the middle of the square.
const SQUARE_NORTH_SOUTH = 0.001 * METRES_PER_DEGREE;
const SQUARE_EAST_WEST = 0.001 * Math.cos((-15.4005 * Math.PI) / 180) * METRES_PER_DEGREE;

const messages = (boundary) => boundaryShapeProblems(boundary).map((p) => p.message);

describe('areaSquareMetres', () => {
  it('measures a square as its two sides multiplied', () => {
    expect(areaSquareMetres(SQUARE)).toBeCloseTo(SQUARE_NORTH_SOUTH * SQUARE_EAST_WEST, 3);
  });

  it('gives the same area whichever way round the corners go', () => {
    expect(areaSquareMetres([...SQUARE].reverse())).toBeCloseTo(areaSquareMetres(SQUARE), 6);
  });

  it('is about zero for corners on one line', () => {
    const line = [
      [-15.4, 28.3],
      [-15.401, 28.301],
      [-15.402, 28.302],
    ];
    expect(areaSquareMetres(line)).toBeLessThan(1e-3);
  });
});

describe('spanMetres', () => {
  it('measures the bounding box sides', () => {
    const span = spanMetres(SQUARE);

    expect(span.northSouth).toBeCloseTo(SQUARE_NORTH_SOUTH, 6);
    expect(span.eastWest).toBeCloseTo(SQUARE_EAST_WEST, 6);
  });
});

describe('boundaryShapeProblems: accepted shapes', () => {
  it('accepts a plain square', () => {
    expect(boundaryShapeProblems(SQUARE)).toEqual([]);
  });

  it('accepts the seeded ZCAS campus boundary, so the seed keeps working', () => {
    expect(boundaryShapeProblems(ZCAS_CAMPUS_BOUNDARY)).toEqual([]);
  });

  it(`accepts a square just over ${MIN_ZONE_AREA_SQUARE_METRES} square metres (about 11 m x 11 m)`, () => {
    const small = [
      [-15.4, 28.3],
      [-15.4, 28.3001],
      [-15.4001, 28.3001],
      [-15.4001, 28.3],
    ];
    expect(areaSquareMetres(small)).toBeGreaterThan(MIN_ZONE_AREA_SQUARE_METRES);
    expect(boundaryShapeProblems(small)).toEqual([]);
  });

  it('accepts a zone just under the size limit (about 49 km north-south)', () => {
    const tall = [
      [-15.2, 28.3],
      [-15.2, 28.31],
      [-15.64, 28.31],
      [-15.64, 28.3],
    ];
    expect(boundaryShapeProblems(tall)).toEqual([]);
  });

  it('accepts corners exactly on the edge of the Zambia box', () => {
    const onEdge = [
      [ZAMBIA_BOUNDS.minLat, 25],
      [-18.49, 25.01],
      [-18.49, 24.99],
    ];
    expect(boundaryShapeProblems(onEdge)).toEqual([]);
  });

  it('allows the same corner twice when the two are not next to each other', () => {
    // Odd, but a real boundary can touch itself at one point; only neighbours are checked.
    const touching = [SQUARE[0], SQUARE[1], SQUARE[2], SQUARE[0], SQUARE[3]];
    expect(messages(touching)).not.toContainEqual(expect.stringContaining('repeats'));
  });
});

describe('boundaryShapeProblems: repeated corners', () => {
  it('refuses a corner that repeats the one before it, pointing at the repeat', () => {
    const boundary = [SQUARE[0], SQUARE[1], SQUARE[1], SQUARE[2], SQUARE[3]];

    expect(boundaryShapeProblems(boundary)).toEqual([
      { path: [2], message: 'repeats the corner before it; list each corner once' },
    ]);
  });

  it('refuses a closed ring (first corner repeated at the end) with a message saying what to change', () => {
    const closed = [...SQUARE, SQUARE[0]];

    expect(boundaryShapeProblems(closed)).toEqual([
      {
        path: [4],
        message: 'repeats the first corner; list each corner once, without repeating the first corner at the end',
      },
    ]);
  });

  it('refuses fewer than 3 different corners, without also measuring the area', () => {
    const boundary = [SQUARE[0], SQUARE[1], SQUARE[0]];

    expect(boundaryShapeProblems(boundary)).toEqual([
      expect.objectContaining({ path: [2], message: expect.stringContaining('repeats the first corner') }),
      { path: [], message: 'must have at least 3 different corners' },
    ]);
  });
});

describe('boundaryShapeProblems: area and size', () => {
  it('refuses corners on one line', () => {
    const line = [
      [-15.4, 28.3],
      [-15.401, 28.301],
      [-15.402, 28.302],
    ];

    expect(boundaryShapeProblems(line)).toEqual([
      {
        path: [],
        message: `must enclose at least ${MIN_ZONE_AREA_SQUARE_METRES} square metres; check that the corners are not all on one line`,
      },
    ]);
  });

  it('refuses a triangle of about 15 square metres', () => {
    const tiny = [
      [-15.4, 28.3],
      [-15.40005, 28.3],
      [-15.4, 28.30005],
    ];

    expect(messages(tiny)).toEqual([expect.stringContaining('must enclose at least')]);
  });

  it.each([
    [
      'north to south (about 51 km)',
      [
        [-15.2, 28.3],
        [-15.2, 28.31],
        [-15.66, 28.31],
        [-15.66, 28.3],
      ],
    ],
    [
      'east to west (about 54 km)',
      [
        [-15.4, 28.0],
        [-15.4, 28.5],
        [-15.41, 28.5],
        [-15.41, 28.0],
      ],
    ],
  ])('refuses a zone wider than the limit %s', (_label, boundary) => {
    expect(boundaryShapeProblems(boundary)).toEqual([
      { path: [], message: `must fit within ${MAX_ZONE_SPAN_METRES / 1000} km from north to south and from east to west` },
    ]);
  });
});

describe('boundaryShapeProblems: the Zambia box', () => {
  it('refuses corners pasted in [lng, lat] order, once, naming the first corner', () => {
    const swapped = SQUARE.map(([lat, lng]) => [lng, lat]);

    const problems = boundaryShapeProblems(swapped);

    expect(problems).toEqual([expect.objectContaining({ path: [0] })]);
    expect(problems[0].message).toContain('each corner must be [latitude, longitude], latitude first');
  });

  it('points at the one corner outside the box', () => {
    const boundary = [
      [-18.45, 25.0],
      [-18.45, 25.1],
      [-18.55, 25.05],
    ];

    expect(boundaryShapeProblems(boundary)).toEqual([expect.objectContaining({ path: [2], message: expect.stringContaining('is outside Zambia') })]);
  });

  it('reports every kind of problem at once', () => {
    const closedAndSwapped = [...SQUARE, SQUARE[0]].map(([lat, lng]) => [lng, lat]);

    expect(boundaryShapeProblems(closedAndSwapped).map((p) => p.path)).toEqual([[4], [0]]);
  });
});
