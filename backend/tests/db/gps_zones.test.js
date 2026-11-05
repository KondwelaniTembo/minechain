import { describe, it, expect } from 'vitest';
import { useTestDb, expectPgError, PG_ERROR } from './helpers.js';
import { MISSING_ID, SAMPLE_BOUNDARY, insertUser, insertZone, zoneInsert } from './fixtures.js';

const t = useTestDb();

async function newAdmin() {
  return insertUser(t.db, { role: 'admin', status: 'active' });
}

async function expectZoneRejected(overrides, code) {
  const admin = await newAdmin();
  const { text, params } = zoneInsert({ created_by: admin.id, ...overrides });
  return expectPgError(t.db, text, params, code);
}

describe('gps_zones table', () => {
  it('stores a valid zone with status active by default', async () => {
    const admin = await newAdmin();
    const { rows } = await t.db.query(
      'INSERT INTO gps_zones (name, boundary, created_by) VALUES ($1, $2, $3) RETURNING *',
      ['Kasempa North', JSON.stringify(SAMPLE_BOUNDARY), admin.id],
    );

    expect(rows[0].status).toBe('active');
    // jsonb comes back already parsed into JavaScript arrays.
    expect(rows[0].boundary).toEqual(SAMPLE_BOUNDARY);
  });

  describe('boundary', () => {
    it.each([
      ['an object instead of an array', { lat: -13.45, lng: 25.82 }],
      ['only 2 corners', SAMPLE_BOUNDARY.slice(0, 2)],
    ])('rejects %s', async (_label, boundary) => {
      const err = await expectZoneRejected({ boundary }, PG_ERROR.CHECK_VIOLATION);

      expect(err.constraint).toBe('gps_zones_boundary_min_3_points');
    });

    it.each([
      ['a corner with 3 numbers', [[-13.45, 25.82, 1200], ...SAMPLE_BOUNDARY.slice(1)]],
      ['a coordinate given as a string', [[-13.45, '25.82'], ...SAMPLE_BOUNDARY.slice(1)]],
      ['a latitude of 95', [[95, 25.82], ...SAMPLE_BOUNDARY.slice(1)]],
      ['a longitude of 200', [[-13.45, 200], ...SAMPLE_BOUNDARY.slice(1)]],
      ['a corner that is a number, not a pair', [-13.45, ...SAMPLE_BOUNDARY.slice(1)]],
    ])('rejects %s', async (_label, boundary) => {
      const err = await expectZoneRejected({ boundary }, PG_ERROR.CHECK_VIOLATION);

      expect(err.constraint).toBe('gps_zones_boundary_points_valid');
    });

    // Without these, the reject tests above could pass simply because the rule rejects
    // every boundary, which is exactly what lax-mode jsonpath did.
    it.each([
      ['SAMPLE_BOUNDARY', SAMPLE_BOUNDARY],
      ['corners exactly on the limits', [[-90, -180], [90, 180], [0, 0]]],
      ['whole-number coordinates', [[-13, 25], [-14, 26], [-15, 25]]],
      ['a closed ring of 5 corners', [[-13.4, 25.8], [-13.4, 25.9], [-13.5, 25.9], [-13.5, 25.8], [-13.4, 25.8]]],
    ])('boundary_points_valid accepts %s', async (_label, boundary) => {
      // An insert that succeeds means no constraint fired, including this one. Each case
      // has at least 3 corners, so min_3_points cannot be the reason a broken rule passes.
      const zone = await insertZone(t.db, { boundary });

      expect(zone.boundary).toEqual(boundary);
    });

    it('fails a non-array boundary as a CHECK violation, not a jsonpath error', async () => {
      // Breaks both boundary rules; min_3_points is reported because CHECKs run in name
      // order. The point is the code: 23514, not 22039 from strict jsonpath.
      await expectZoneRejected({ boundary: 'not-a-polygon' }, PG_ERROR.CHECK_VIOLATION);
    });
  });

  it('rejects a name that differs only in letter case', async () => {
    await insertZone(t.db, { name: 'Kasempa North' });

    await expectZoneRejected({ name: 'kasempa north' }, PG_ERROR.UNIQUE_VIOLATION);
  });

  it.each([
    ['an unknown status', { status: 'closed' }, 'gps_zones_status_valid'],
    ['a blank name', { name: '   ' }, 'gps_zones_name_not_blank'],
  ])('rejects %s', async (_label, overrides, constraint) => {
    const err = await expectZoneRejected(overrides, PG_ERROR.CHECK_VIOLATION);

    expect(err.constraint).toBe(constraint);
  });

  it('rejects created_by pointing at a user that does not exist', async () => {
    const { text, params } = zoneInsert({ created_by: MISSING_ID });

    await expectPgError(t.db, text, params, PG_ERROR.FOREIGN_KEY_VIOLATION);
  });

  it('refuses to delete the admin who created a zone (D9)', async () => {
    const zone = await insertZone(t.db);

    const err = await expectPgError(
      t.db,
      'DELETE FROM users WHERE id = $1',
      [zone.created_by],
      PG_ERROR.RESTRICT_VIOLATION,
    );
    expect(err.constraint).toBe('gps_zones_created_by_fkey');
  });

  it('moves updated_at forward on update', async () => {
    // now() is fixed for the whole test transaction, so the row starts with an old
    // updated_at; otherwise "before" and "after" would be identical. The trigger only runs
    // on UPDATE, so the INSERT keeps the old value.
    const OLD = new Date('2020-01-01T00:00:00Z');
    const admin = await newAdmin();
    const { rows: inserted } = await t.db.query(
      `INSERT INTO gps_zones (name, boundary, created_by, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $4) RETURNING id`,
      ['Old Zone', JSON.stringify(SAMPLE_BOUNDARY), admin.id, OLD],
    );

    const { rows } = await t.db.query(
      "UPDATE gps_zones SET status = 'inactive' WHERE id = $1 RETURNING updated_at",
      [inserted[0].id],
    );

    expect(rows[0].updated_at.getTime()).toBeGreaterThan(OLD.getTime());
  });
});
