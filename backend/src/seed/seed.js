import { randomBytes } from 'node:crypto';
import { usernameSchema } from '../schemas/auth.js';
import { zoneBoundarySchema } from '../schemas/geo.js';
import { checkPasswordPolicy } from '../services/passwordPolicy.js';
import { createPasswordService } from '../services/passwordService.js';
import { createAuditService } from '../services/auditService.js';
import { DEMO_USERS, DEMO_ZONE, SEED_ADMIN_FULL_NAME } from './seedData.js';

export const PRODUCTION_FLAG = '--production-admin-only';

// A refusal the person running the seed can fix (a missing variable, a weak password, a
// zone with no corners). The command-line wrapper prints its message as it is. Messages
// name variables and rules, never the values, so a password cannot reach the terminal or
// Render's logs.
export class SeedError extends Error {
  constructor(message) {
    super(message);
    this.name = 'SeedError';
  }
}

// The status is written into the SQL, not passed in, so the seed can only create active
// accounts and nothing else can slip through. approved_by stays NULL: nobody approved
// these accounts, and the users.create audit entry records where they came from.
// ON CONFLICT names the expression of the users_username_lower_key index, so a clash in
// any letter case does nothing instead of failing, and the existing row is never changed.
// When nothing is inserted, RETURNING gives no row; the caller then reads the existing one.
const INSERT_USER = `
  INSERT INTO users (username, full_name, licence_number, password_hash, role, status, actor_ref)
  VALUES ($1, $2, $3, $4, $5, 'active', $6)
  ON CONFLICT (lower(username)) DO NOTHING
  RETURNING id`;

const SELECT_USER = `
  SELECT id, role, status
    FROM users
   WHERE lower(username) = lower($1)`;

// Same idea for zones, through the gps_zones_name_lower_key index. status takes its
// default ('active').
const INSERT_ZONE = `
  INSERT INTO gps_zones (name, licence_number, boundary, created_by)
  VALUES ($1, NULL, $2, $3)
  ON CONFLICT (lower(name)) DO NOTHING
  RETURNING id`;

const PLACEHOLDER_PREFIX = 'replace-with';

// Reads one required variable. Returns null and adds a problem when it is unusable.
function readRequired(env, name, problems) {
  const value = env[name];
  if (value === undefined || value === '') {
    problems.push(`${name}: is missing`);
    return null;
  }
  // Catches a .env copied from .env.example without the value being replaced. The fake
  // value could otherwise pass the password policy and become a real, published password.
  if (value.startsWith(PLACEHOLDER_PREFIX)) {
    problems.push(`${name}: still holds the .env.example placeholder`);
    return null;
  }
  return value;
}

// Policy problems as "VARIABLE: CODE (message)". The policy's own messages never repeat
// the password, so this is safe to print.
function policyProblems(name, password, username) {
  return checkPasswordPolicy(password, { username }).map(
    ({ code, message }) => `${name}: ${code} (${message})`,
  );
}

function boundaryProblems(zone) {
  if (Array.isArray(zone.boundary) && zone.boundary.length === 0) {
    // The default zone ships empty on purpose; say exactly what to do rather than show
    // Zod's "must have at least 3 corners".
    return [
      `GPS zone "${zone.name}" has no corners yet: fill in ZCAS_CAMPUS_BOUNDARY in ` +
        'src/seed/seedData.js (see the comment there for the [lat, lng] order)',
    ];
  }
  const result = zoneBoundarySchema.safeParse(zone.boundary);
  if (result.success) return [];
  // For example "boundary[1][0]: must have at most 6 decimal places" (corner 2, latitude).
  return result.error.issues.map(
    (issue) => `GPS zone "${zone.name}" boundary${issue.path.map((p) => `[${p}]`).join('')}: ${issue.message}`,
  );
}

// Checks everything before any database work, and reports every problem at once so one
// run shows the whole list instead of one fix per run.
function checkInputs({ env, args, zone }) {
  const unknownArgs = args.filter((arg) => arg !== PRODUCTION_FLAG);
  if (unknownArgs.length > 0) {
    // A misspelt flag must not be ignored: in development it would quietly create demo
    // users the person meant to leave out.
    throw new SeedError(`Unknown argument(s): ${unknownArgs.join(' ')}. The only option is ${PRODUCTION_FLAG}.`);
  }

  const productionAdminOnly = args.includes(PRODUCTION_FLAG);
  const nodeEnv = env.NODE_ENV ?? 'development';
  // First, before anything else is read or written: demo accounts with a shared, known
  // password must never reach a real database by accident.
  if (nodeEnv === 'production' && !productionAdminOnly) {
    throw new SeedError(
      `Refusing to seed while NODE_ENV is production. To create only the admin and the GPS ` +
        `zone, run: npm run seed -- ${PRODUCTION_FLAG}`,
    );
  }

  const problems = [];

  const rawUsername = readRequired(env, 'SEED_ADMIN_USERNAME', problems);
  let adminUsername = null;
  if (rawUsername !== null) {
    const parsed = usernameSchema.safeParse(rawUsername);
    if (parsed.success) {
      adminUsername = parsed.data;
    } else {
      problems.push(...parsed.error.issues.map((issue) => `SEED_ADMIN_USERNAME: ${issue.message}`));
    }
  }

  const adminPassword = readRequired(env, 'SEED_ADMIN_PASSWORD', problems);
  if (adminPassword !== null) {
    problems.push(...policyProblems('SEED_ADMIN_PASSWORD', adminPassword, adminUsername ?? undefined));
  }

  // Demo users: never with the flag; otherwise only when a demo password is set.
  let demoPassword = null;
  let demoSkipReason = null;
  if (productionAdminOnly) {
    demoSkipReason = `${PRODUCTION_FLAG} was given`;
  } else if (env.SEED_DEMO_PASSWORD === undefined || env.SEED_DEMO_PASSWORD === '') {
    demoSkipReason = 'SEED_DEMO_PASSWORD is not set';
  } else {
    demoPassword = readRequired(env, 'SEED_DEMO_PASSWORD', problems);
    if (demoPassword !== null) {
      // Checked against every demo username, because the password must not contain any
      // of them. A Set drops the same problem repeated for each account.
      const demoProblems = new Set(
        DEMO_USERS.flatMap((user) => policyProblems('SEED_DEMO_PASSWORD', demoPassword, user.username)),
      );
      problems.push(...demoProblems);
    }
  }

  problems.push(...boundaryProblems(zone));

  if (problems.length > 0) {
    throw new SeedError(`Seed refused. Nothing was written. Fix these and run it again:\n${problems.map((p) => `  - ${p}`).join('\n')}`);
  }

  return { nodeEnv, adminUsername, adminPassword, demoPassword, demoSkipReason };
}

// Seeds the first admin, the demo GPS zone and (outside production) one active demo user
// per role. Safe to run again: existing rows are left exactly as they are.
//   db:        the app's db object (a pool, or a connection inside a test's transaction)
//   env:       variables to read, normally process.env
//   args:      command-line arguments after the script name
//   log:       where progress lines go; tests pass a collector
//   zone:      { name, boundary }; tests pass their own so they never use the real corners
//   passwords: the Argon2id service; tests may pass a fast fake
//   audit:     the audit service
export async function runSeed({
  db,
  env,
  args = [],
  log = console.log,
  zone = DEMO_ZONE,
  passwords = createPasswordService(),
  audit = createAuditService(),
}) {
  const { nodeEnv, adminUsername, adminPassword, demoPassword, demoSkipReason } = checkInputs({ env, args, zone });

  const demoUsers = demoPassword === null ? [] : DEMO_USERS;

  // Hashed before the transaction opens, as in userService.register: Argon2 takes about
  // 50 ms each, and the transaction should hold its locks as briefly as possible. Each
  // demo account gets its own hash (its own salt), even with a shared password.
  const adminHash = await passwords.hash(adminPassword);
  const demoHashes = await Promise.all(demoUsers.map(() => passwords.hash(demoPassword)));

  const counts = { users: { created: 0, existed: 0 }, zones: { created: 0, existed: 0 } };
  const notes = [];

  // Inserts one user, or finds the existing one. The audit entry is written only for a row
  // actually created, in the same transaction, so the two are saved together or not at all.
  // actorId is NULL: no person did this (nobody logged in, there is no request), and the
  // audit_logs schema reserves NULL for system actions. source: 'seed' tells these apart
  // from accounts an administrator creates later through FR-10.
  const ensureUser = async (tx, { username, fullName, licenceNumber, role }, passwordHash) => {
    const { rows } = await tx.query(INSERT_USER, [username, fullName, licenceNumber, passwordHash, role, randomBytes(32)]);
    if (rows.length === 1) {
      counts.users.created += 1;
      await audit.record(tx, {
        action: 'user.create',
        entityType: 'user',
        entityId: rows[0].id,
        details: { source: 'seed', role },
      });
      return { id: rows[0].id, role, status: 'active', created: true };
    }

    counts.users.existed += 1;
    const existing = await tx.query(SELECT_USER, [username]);
    if (existing.rows.length !== 1) {
      // The clash was seen but the row is gone: something else is changing users at the
      // same moment. Stop rather than guess.
      throw new Error('A user changed while the seed was running; run it again');
    }
    return { ...existing.rows[0], created: false };
  };

  await db.transaction(async (tx) => {
    const admin = await ensureUser(
      tx,
      { username: adminUsername, fullName: SEED_ADMIN_FULL_NAME, licenceNumber: null, role: 'admin' },
      adminHash,
    );
    // The seed never changes an existing account. If the name belongs to someone who is
    // not an active admin (for example a miner who registered "admin"), the zone must not
    // be recorded as configured by them, so everything is rolled back.
    if (!admin.created && (admin.role !== 'admin' || admin.status !== 'active')) {
      throw new SeedError(
        'SEED_ADMIN_USERNAME belongs to an existing account that is not an active admin. ' +
          'The seed never changes existing accounts, so nothing was written. Choose another ' +
          'username, or sort out that account first.',
      );
    }

    // JSON.stringify: pg would send an array as a PostgreSQL array, not as JSON.
    const { rows } = await tx.query(INSERT_ZONE, [zone.name, JSON.stringify(zone.boundary), admin.id]);
    if (rows.length === 1) {
      counts.zones.created += 1;
      await audit.record(tx, {
        action: 'gps_zone.create',
        entityType: 'gps_zone',
        entityId: rows[0].id,
        details: { source: 'seed', name: zone.name },
      });
    } else {
      counts.zones.existed += 1;
    }

    for (const [index, user] of demoUsers.entries()) {
      const result = await ensureUser(tx, user, demoHashes[index]);
      if (!result.created && (result.role !== user.role || result.status !== 'active')) {
        // Left alone on purpose, but worth saying: logging in as it may not work as expected.
        notes.push(`${user.username} already exists as a ${result.status} ${result.role}; left unchanged`);
      }
    }
  });

  // Printed only after the commit, so "created" always means saved.
  log(`Seed finished (NODE_ENV=${nodeEnv}).`);
  log(`  Users:     ${counts.users.created} created, ${counts.users.existed} already existed`);
  log(`  GPS zones: ${counts.zones.created} created, ${counts.zones.existed} already existed (existing zones are never changed)`);
  log(demoSkipReason ? `  Demo users skipped: ${demoSkipReason}.` : `  Demo users included: ${DEMO_USERS.map((u) => u.username).join(', ')}`);
  for (const note of notes) log(`  Note: ${note}`);

  return { ...counts, demoUsers: demoSkipReason ? 'skipped' : 'included' };
}
