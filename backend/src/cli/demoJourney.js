// DEV-SHORTCUT: signs custody steps on the server with throwaway in-memory keys instead of phones | remove before release; real steps are signed on the device (NFR-02)
//
// npm run demo:journey: one complete custody chain through the real pipeline, so the
// anchoring worker has something to send before the app exists. It:
//   1. creates three FRESH active users (miner, transporter, buyer) with a random suffix.
//      It never touches the seed_* demo users, whose keys the phone will register later
//      (a user's key can only be set once without an administrator);
//   2. gives each a P-256 key pair that lives only in this process's memory, and registers
//      the public half through the user service, as PUT /auth/me/public-key does;
//   3. signs a registration, a handoff and a purchase for a fresh QR code and syncs each
//      through the sync service, so every check a phone's upload meets applies here too.
//
// The private keys are never written or printed, and are gone when the process exits. The
// accounts get a random password nobody ever sees, so nobody can log in as them.
// Refused when NODE_ENV is production (fake custody records on a real system) or test (the
// test database is only for the rolled-back tests).
import { generateKeyPairSync, randomBytes, randomUUID, sign } from 'node:crypto';
import { canonicalise } from '../services/stepPayload.js';
import { createPasswordService } from '../services/passwordService.js';
import { createAuditService } from '../services/auditService.js';

export class DemoJourneyError extends Error {
  constructor(message) {
    super(message);
    this.name = 'DemoJourneyError';
  }
}

const ROLES = Object.freeze(['miner', 'transporter', 'buyer']);
const STEP_FOR_ROLE = Object.freeze({ miner: 'registration', transporter: 'handoff', buyer: 'purchase' });

// The status is fixed in the SQL, as in the seed: this script can only create active
// accounts. A clash on a random name fails the transaction rather than reusing an account.
const INSERT_USER = `
  INSERT INTO users (username, full_name, licence_number, password_hash, role, status, actor_ref)
  VALUES ($1, $2, NULL, $3, $4, 'active', $5)
  RETURNING id`;

export function assertDemoAllowed(nodeEnv) {
  if (nodeEnv === 'production' || nodeEnv === 'test') {
    throw new DemoJourneyError(
      `Refusing to run demo:journey while NODE_ENV is ${nodeEnv}. It creates fake accounts and custody ` +
        'records, so it only runs against a development database.',
    );
  }
}

// db and services: the app's db object and createServices' result. log: one line at a
// time. Returns what was created (no keys), for the caller and the tests.
export async function runDemoJourney({
  db,
  services,
  nodeEnv,
  log = console.log,
  passwords = createPasswordService(),
  audit = createAuditService(),
  now = () => new Date(),
}) {
  // First, before anything is read or written.
  assertDemoAllowed(nodeEnv);

  const suffix = randomBytes(3).toString('hex');
  // Hashed before the transaction, like the seed; the passwords are thrown away at once.
  const hashes = await Promise.all(ROLES.map(() => passwords.hash(randomBytes(32).toString('base64url'))));

  const users = await db.transaction(async (tx) => {
    const created = [];
    for (const [i, role] of ROLES.entries()) {
      const username = `demo_${role}_${suffix}`;
      const { rows } = await tx.query(INSERT_USER, [username, `Demo journey ${role}`, hashes[i], role, randomBytes(32)]);
      await audit.record(tx, {
        action: 'user.create',
        entityType: 'user',
        entityId: rows[0].id,
        details: { source: 'demo-journey', role },
      });
      created.push({ id: rows[0].id, username, role });
    }
    return created;
  });

  // One key pair per user, in memory only.
  const phones = new Map();
  for (const user of users) {
    const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const spki = publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
    await services.users.registerPublicKey(user.id, spki);
    phones.set(user.id, privateKey);
  }

  // The suffix too, so two runs in the same millisecond still get different codes.
  const qrCode = `MC-DEMO-${now().getTime()}-${suffix}`;
  log(`Demo journey for ${qrCode}`);
  log(`  Users: ${users.map((u) => u.username).join(', ')}`);

  const steps = [];
  for (const [i, user] of users.entries()) {
    const type = STEP_FOR_ROLE[user.role];
    const fields = {
      type,
      stepId: randomUUID(),
      actorId: user.id,
      qrCode,
      ...(type === 'registration' && { mineral: 'gold' }),
      // Within 10% of each other, so the quantity check (when it exists) passes.
      weightMg: ['1500000', '1495000', '1494000'][i],
      latitude: '-15.419751',
      longitude: '28.287496',
      // A minute apart, ending a minute ago: captured before they are received.
      capturedAt: new Date(now().getTime() - (ROLES.length - i) * 60_000).toISOString(),
    };
    const payload = canonicalise(fields);
    // SHA256withECDSA, DER, base64: exactly what the Android app sends.
    const signature = sign('sha256', Buffer.from(payload, 'utf8'), phones.get(user.id)).toString('base64');

    const [result] = await services.sync.syncSteps({ id: user.id, role: user.role }, [{ payload, signature }]);
    const line = `${result.outcome}${result.reviewStatus ? ` (${result.reviewStatus})` : ''}${result.code ? ` ${result.code}` : ''}`;
    log(`  ${type.padEnd(12)} ${line}${result.transactionId ? `, step ${result.transactionId}` : ''}`);
    steps.push({ type, outcome: result.outcome, reviewStatus: result.reviewStatus ?? null, code: result.code ?? null, transactionId: result.transactionId ?? null });
  }
  phones.clear();

  log('Next: npm run anchor:once -- --until-idle');
  return { qrCode, users: users.map(({ username, role }) => ({ username, role })), steps };
}
