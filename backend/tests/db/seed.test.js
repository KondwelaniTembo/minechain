import { describe, it, expect } from 'vitest';
import { runSeed, SeedError, PRODUCTION_FLAG } from '../../src/seed/seed.js';
import { DEMO_USERS } from '../../src/seed/seedData.js';
import { createPasswordService } from '../../src/services/passwordService.js';
import { useTestDb } from './helpers.js';
import { insertUser, FAKE_ARGON2_HASH } from './fixtures.js';

const ctx = useTestDb();

// All values are fake. The passwords meet the policy and contain none of the usernames.
const ADMIN_PASSWORD = 'copper lantern kafue morning';
const DEMO_PASSWORD = 'emerald bridge lundazi dawn';
const ENV = Object.freeze({
  NODE_ENV: 'development',
  SEED_ADMIN_USERNAME: 'test_seed_admin',
  SEED_ADMIN_PASSWORD: ADMIN_PASSWORD,
  SEED_DEMO_PASSWORD: DEMO_PASSWORD,
});

// The tests' own zone, so they never depend on the real campus corners in seedData.js.
const ZONE = Object.freeze({
  name: 'Test Seed Zone',
  boundary: [
    [-15.39, 28.32],
    [-15.4, 28.33],
    [-15.41, 28.31],
  ],
});

// Argon2 costs about 50 ms per hash, and these tests seed many times, so most use a fake
// that returns a well-formed hash. One test below uses the real service.
const fakePasswords = { hash: async () => FAKE_ARGON2_HASH };

// Runs the seed with the test database, collecting what it prints.
async function seed({ env = ENV, args = [], zone = ZONE, passwords = fakePasswords } = {}) {
  const lines = [];
  const summary = await runSeed({ db: ctx.db, env, args, zone, passwords, log: (line) => lines.push(line) });
  return { summary, lines, output: lines.join('\n') };
}

// Runs a seed that must be refused and returns the error. The refusal happens inside the
// test's transaction (as a savepoint), so the test can go on querying afterwards.
async function seedRefused(options) {
  const err = await seed(options).then(
    () => null,
    (e) => e,
  );
  expect(err, 'the seed should have been refused').toBeInstanceOf(SeedError);
  return err;
}

async function counts() {
  const { rows } = await ctx.db.query(`
    SELECT (SELECT count(*) FROM users)::int      AS users,
           (SELECT count(*) FROM gps_zones)::int  AS zones,
           (SELECT count(*) FROM audit_logs)::int AS audits`);
  return rows[0];
}

const NOTHING = { users: 0, zones: 0, audits: 0 };
const ALL_DEMO = DEMO_USERS.length;

describe('runSeed: first run in development', () => {
  it('creates the admin, the zone and one active demo user per role', async () => {
    const { summary } = await seed();

    expect(summary).toEqual({
      users: { created: 1 + ALL_DEMO, existed: 0 },
      zones: { created: 1, existed: 0 },
      demoUsers: 'included',
    });

    const { rows: users } = await ctx.db.query(
      'SELECT username, role, status, licence_number, approved_by, approved_at FROM users ORDER BY username',
    );
    expect(users).toEqual([
      { username: 'seed_buyer', role: 'buyer', status: 'active', licence_number: 'DEMO-BUY-0001', approved_by: null, approved_at: null },
      { username: 'seed_miner', role: 'miner', status: 'active', licence_number: 'DEMO-ASM-0001', approved_by: null, approved_at: null },
      { username: 'seed_officer', role: 'officer', status: 'active', licence_number: null, approved_by: null, approved_at: null },
      { username: 'seed_transporter', role: 'transporter', status: 'active', licence_number: null, approved_by: null, approved_at: null },
      { username: 'test_seed_admin', role: 'admin', status: 'active', licence_number: null, approved_by: null, approved_at: null },
    ]);
  });

  it('records the zone as configured by the admin, with the boundary unchanged', async () => {
    await seed();

    const { rows } = await ctx.db.query(
      `SELECT z.name, z.boundary, z.status, u.username AS created_by
         FROM gps_zones z JOIN users u ON u.id = z.created_by`,
    );
    expect(rows).toEqual([{ name: ZONE.name, boundary: ZONE.boundary, status: 'active', created_by: 'test_seed_admin' }]);
  });

  it('writes one audit entry per created row, with no actor and source "seed"', async () => {
    await seed();

    const { rows } = await ctx.db.query(
      'SELECT actor_id, action, entity_type, details, ip_address FROM audit_logs ORDER BY id',
    );
    expect(rows).toHaveLength(2 + ALL_DEMO);
    for (const row of rows) {
      expect(row.actor_id).toBeNull();
      expect(row.ip_address).toBeNull();
      expect(row.details.source).toBe('seed');
    }
    expect(rows.map((r) => r.action)).toEqual(['user.create', 'gps_zone.create', ...DEMO_USERS.map(() => 'user.create')]);
    expect(rows[0].details).toEqual({ source: 'seed', role: 'admin' });
    expect(rows[1].details).toEqual({ source: 'seed', name: ZONE.name });
  });

  it('points each audit entry at the row it created', async () => {
    await seed();

    const { rows } = await ctx.db.query(`
      SELECT count(*)::int AS matched FROM audit_logs a
       WHERE (a.entity_type = 'user'     AND EXISTS (SELECT 1 FROM users u     WHERE u.id = a.entity_id))
          OR (a.entity_type = 'gps_zone' AND EXISTS (SELECT 1 FROM gps_zones z WHERE z.id = a.entity_id))`);
    expect(rows[0].matched).toBe(2 + ALL_DEMO);
  });
});

describe('runSeed: idempotency', () => {
  it('a second run creates nothing and reports everything as already existing', async () => {
    await seed();
    const before = await counts();

    const { summary } = await seed();

    expect(summary).toEqual({
      users: { created: 0, existed: 1 + ALL_DEMO },
      zones: { created: 0, existed: 1 },
      demoUsers: 'included',
    });
    // No new users, zones or audit entries.
    expect(await counts()).toEqual(before);
  });

  it('matches existing names in any letter case', async () => {
    await seed();
    const before = await counts();

    const { summary } = await seed({
      env: { ...ENV, SEED_ADMIN_USERNAME: 'TEST_SEED_ADMIN' },
      zone: { ...ZONE, name: 'TEST SEED ZONE' },
    });

    expect(summary.users.created).toBe(0);
    expect(summary.zones.created).toBe(0);
    expect(await counts()).toEqual(before);
  });

  it('uses an admin that already exists as the zone owner', async () => {
    const existingAdmin = await insertUser(ctx.db, { username: 'test_seed_admin', role: 'admin', status: 'active' });

    const { summary } = await seed();

    expect(summary.users).toEqual({ created: ALL_DEMO, existed: 1 });
    const { rows } = await ctx.db.query('SELECT created_by FROM gps_zones');
    expect(rows[0].created_by).toBe(existingAdmin.id);
  });

  it('never changes an existing account, such as a pending demo_miner or seed_miner', async () => {
    await insertUser(ctx.db, { username: 'demo_miner', role: 'miner', status: 'pending' });
    await insertUser(ctx.db, { username: 'seed_miner', role: 'miner', status: 'pending', full_name: 'Someone Else' });
    // ctid is the row's physical position. An UPDATE writes a new row version at a new
    // position, even inside one transaction, where updated_at would not move (now() is
    // fixed for the whole transaction). So an unchanged ctid proves no UPDATE happened.
    const snapshot = () =>
      ctx.db.query(
        `SELECT username, ctid::text, full_name, role, status, password_hash, licence_number, actor_ref
           FROM users WHERE username IN ('demo_miner', 'seed_miner') ORDER BY username`,
      );
    const before = (await snapshot()).rows;

    const { summary, output } = await seed();

    expect((await snapshot()).rows).toEqual(before);
    expect(summary.users).toEqual({ created: 1 + ALL_DEMO - 1, existed: 1 });
    expect(output).toContain('seed_miner already exists as a pending miner; left unchanged');
  });

  it('never changes an existing zone with the same name', async () => {
    await seed();
    const otherBoundary = [[-15.3, 28.2], [-15.31, 28.21], [-15.32, 28.19]];

    await seed({ zone: { ...ZONE, boundary: otherBoundary } });

    const { rows } = await ctx.db.query('SELECT boundary FROM gps_zones');
    expect(rows[0].boundary).toEqual(ZONE.boundary);
  });
});

describe('runSeed: missing or unusable variables', () => {
  it.each(['SEED_ADMIN_USERNAME', 'SEED_ADMIN_PASSWORD'])('refuses when %s is missing', async (name) => {
    const { [name]: _removed, ...env } = ENV;

    const err = await seedRefused({ env });

    expect(err.message).toContain(`${name}: is missing`);
    expect(await counts()).toEqual(NOTHING);
  });

  it.each(['SEED_ADMIN_USERNAME', 'SEED_ADMIN_PASSWORD'])('refuses when %s is empty', async (name) => {
    const err = await seedRefused({ env: { ...ENV, [name]: '' } });

    expect(err.message).toContain(`${name}: is missing`);
  });

  it.each(['SEED_ADMIN_USERNAME', 'SEED_ADMIN_PASSWORD', 'SEED_DEMO_PASSWORD'])(
    'refuses the .env.example placeholder in %s',
    async (name) => {
      const err = await seedRefused({ env: { ...ENV, [name]: 'replace-with-a-long-passphrase-here' } });

      expect(err.message).toContain(`${name}: still holds the .env.example placeholder`);
      expect(await counts()).toEqual(NOTHING);
    },
  );

  it('lists every problem at once', async () => {
    const err = await seedRefused({ env: { NODE_ENV: 'development' } });

    expect(err.message).toContain('SEED_ADMIN_USERNAME: is missing');
    expect(err.message).toContain('SEED_ADMIN_PASSWORD: is missing');
  });

  it('refuses an admin username the registration rule would refuse', async () => {
    const err = await seedRefused({ env: { ...ENV, SEED_ADMIN_USERNAME: 'test seed admin' } });

    expect(err.message).toContain('SEED_ADMIN_USERNAME: may only use letters, digits, and _ . -');
  });

  it.each([
    ['too short', 'kafue river', 'PASSWORD_TOO_SHORT'],
    ['containing the username', 'test_seed_admin rocks!', 'PASSWORD_CONTAINS_USERNAME'],
    ['one character repeated', 'zzzzzzzzzzzzzzzz', 'PASSWORD_REPEATED'],
  ])('refuses an admin password %s', async (_label, password, code) => {
    const err = await seedRefused({ env: { ...ENV, SEED_ADMIN_PASSWORD: password } });

    expect(err.message).toContain(`SEED_ADMIN_PASSWORD: ${code}`);
    expect(await counts()).toEqual(NOTHING);
  });

  it('refuses a demo password containing a demo username', async () => {
    const err = await seedRefused({ env: { ...ENV, SEED_DEMO_PASSWORD: 'i am seed_buyer today' } });

    expect(err.message).toContain('SEED_DEMO_PASSWORD: PASSWORD_CONTAINS_USERNAME');
    expect(await counts()).toEqual(NOTHING);
  });

  it('refuses an unknown or misspelt argument', async () => {
    const err = await seedRefused({ args: ['--production-admin'] });

    expect(err.message).toContain('Unknown argument(s): --production-admin');
    expect(await counts()).toEqual(NOTHING);
  });
});

describe('runSeed: demo users skipped without a demo password', () => {
  it.each([
    ['missing', undefined],
    ['empty', ''],
  ])('creates only the admin and zone when SEED_DEMO_PASSWORD is %s, and says so', async (_label, value) => {
    const { SEED_DEMO_PASSWORD: _removed, ...rest } = ENV;
    const env = value === undefined ? rest : { ...rest, SEED_DEMO_PASSWORD: value };

    const { summary, output } = await seed({ env });

    expect(summary).toEqual({ users: { created: 1, existed: 0 }, zones: { created: 1, existed: 0 }, demoUsers: 'skipped' });
    expect(output).toContain('Demo users skipped: SEED_DEMO_PASSWORD is not set.');
  });
});

describe('runSeed: production safety', () => {
  it('refuses NODE_ENV=production without the flag, and writes nothing', async () => {
    const err = await seedRefused({ env: { ...ENV, NODE_ENV: 'production' } });

    expect(err.message).toContain('Refusing to seed while NODE_ENV is production');
    expect(err.message).toContain(`npm run seed -- ${PRODUCTION_FLAG}`);
    expect(await counts()).toEqual(NOTHING);
  });

  it('refuses production first, before reporting any missing variable', async () => {
    const err = await seedRefused({ env: { NODE_ENV: 'production' } });

    expect(err.message).toContain('Refusing to seed while NODE_ENV is production');
    expect(err.message).not.toContain('is missing');
  });

  it('with the flag, creates only the admin and the zone, even when a demo password is set', async () => {
    const { summary, output } = await seed({ env: { ...ENV, NODE_ENV: 'production' }, args: [PRODUCTION_FLAG] });

    expect(summary).toEqual({ users: { created: 1, existed: 0 }, zones: { created: 1, existed: 0 }, demoUsers: 'skipped' });
    expect(output).toContain(`Demo users skipped: ${PRODUCTION_FLAG} was given.`);
    const { rows } = await ctx.db.query('SELECT username, role FROM users');
    expect(rows).toEqual([{ username: 'test_seed_admin', role: 'admin' }]);
  });

  it('with the flag, ignores the demo password entirely, even a placeholder', async () => {
    const env = { ...ENV, NODE_ENV: 'production', SEED_DEMO_PASSWORD: 'replace-with-a-long-demo-passphrase' };

    const { summary } = await seed({ env, args: [PRODUCTION_FLAG] });

    expect(summary.demoUsers).toBe('skipped');
  });

  it('the flag also limits a development run to the admin and the zone', async () => {
    const { summary } = await seed({ args: [PRODUCTION_FLAG] });

    expect(summary.users).toEqual({ created: 1, existed: 0 });
  });
});

describe('runSeed: the GPS zone', () => {
  it('refuses an empty boundary with a message saying where to fill it in', async () => {
    const err = await seedRefused({ zone: { name: 'ZCAS Campus (demo)', boundary: [] } });

    expect(err.message).toContain('fill in ZCAS_CAMPUS_BOUNDARY in src/seed/seedData.js');
    expect(await counts()).toEqual(NOTHING);
  });

  it('refuses a corner with more than 6 decimal places, naming the corner', async () => {
    const boundary = [ZONE.boundary[0], [-15.4000001, 28.33], ZONE.boundary[2]];

    const err = await seedRefused({ zone: { ...ZONE, boundary } });

    expect(err.message).toContain('boundary[1][0]: must have at most 6 decimal places');
    expect(await counts()).toEqual(NOTHING);
  });

  it('refuses a boundary with fewer than 3 corners', async () => {
    const err = await seedRefused({ zone: { ...ZONE, boundary: ZONE.boundary.slice(0, 2) } });

    expect(err.message).toContain('must have at least 3 corners');
  });
});

describe('runSeed: an admin username that belongs to someone else', () => {
  it.each([
    ['an active miner', { role: 'miner', status: 'active' }],
    ['a suspended admin', { role: 'admin', status: 'suspended', status_reason: 'Test suspension' }],
  ])('refuses when it is %s, and rolls back everything', async (_label, overrides) => {
    await insertUser(ctx.db, { username: 'test_seed_admin', ...overrides });
    const before = await counts();

    const err = await seedRefused();

    expect(err.message).toContain('not an active admin');
    // The admin lookup happens inside the transaction, so the zone and demo users that
    // would follow are never written, and nothing the transaction did survives.
    expect(await counts()).toEqual(before);
  });
});

describe('runSeed: passwords never appear in output', () => {
  const PASSWORDS = [ADMIN_PASSWORD, DEMO_PASSWORD];

  const expectNoPassword = (text) => {
    for (const password of PASSWORDS) expect(text).not.toContain(password);
  };

  it('not in the printed lines or the returned summary', async () => {
    const { summary, output } = await seed();

    expectNoPassword(output);
    expectNoPassword(JSON.stringify(summary));
  });

  it('not in any audit entry', async () => {
    await seed();

    const { rows } = await ctx.db.query('SELECT details::text AS details FROM audit_logs');
    for (const row of rows) expectNoPassword(row.details);
  });

  it('not in a refusal for a weak password', async () => {
    // Too short on purpose, so both are refused; distinctive, so a leak would be spotted.
    const weak = 'zambezi99';
    const err = await seedRefused({ env: { ...ENV, SEED_ADMIN_PASSWORD: weak, SEED_DEMO_PASSWORD: 'okavango' } });

    expect(err.message).not.toContain(weak);
    expect(err.message).not.toContain('okavango');
  });

  it('not in a refusal for another reason', async () => {
    await insertUser(ctx.db, { username: 'test_seed_admin', role: 'miner', status: 'active' });

    const err = await seedRefused();

    expectNoPassword(err.message);
  });
});

describe('runSeed: with the real Argon2id service', () => {
  it('stores hashes that verify, with a different salt for each demo account', async () => {
    const passwords = createPasswordService();

    await seed({ passwords });

    const { rows } = await ctx.db.query('SELECT username, password_hash FROM users ORDER BY username');
    const admin = rows.find((r) => r.username === 'test_seed_admin');
    const demos = rows.filter((r) => r.username !== 'test_seed_admin');

    expect(admin.password_hash).toMatch(/^\$argon2id\$/);
    expect(await passwords.verify(admin.password_hash, ADMIN_PASSWORD)).toBe(true);
    expect(await passwords.verify(demos[0].password_hash, DEMO_PASSWORD)).toBe(true);
    // Same password, but each hash has its own random salt, so no two are equal.
    expect(new Set(demos.map((r) => r.password_hash)).size).toBe(ALL_DEMO);
  });
});
