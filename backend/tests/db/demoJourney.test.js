import { describe, it, expect } from 'vitest';
import { useTestDb } from './helpers.js';
import { FAKE_ARGON2_HASH, FAKE_CONFIG, insertUser } from './fixtures.js';
import { createServices } from '../../src/services/index.js';
import { runDemoJourney } from '../../src/cli/demoJourney.js';

// The whole journey through the real services, on the rolled-back test transaction. The
// script itself refuses NODE_ENV=test; here the function is called directly with
// "development", which is exactly what the CLI would pass on a developer's machine.

const t = useTestDb();
const fastPasswords = { hash: async () => FAKE_ARGON2_HASH };

async function run() {
  const lines = [];
  const result = await runDemoJourney({
    db: t.db,
    services: createServices({ db: t.db, config: FAKE_CONFIG }),
    nodeEnv: 'development',
    passwords: fastPasswords,
    log: (line) => lines.push(line),
  });
  return { result, output: lines.join('\n') };
}

describe('runDemoJourney', () => {
  it('creates three fresh active users with registered keys, and syncs three passed steps', async () => {
    const { result, output } = await run();

    expect(result.qrCode).toMatch(/^MC-DEMO-\d+-[0-9a-f]{6}$/);
    expect(result.steps.map((s) => [s.type, s.outcome, s.reviewStatus])).toEqual([
      ['registration', 'created', 'passed'],
      ['handoff', 'created', 'passed'],
      ['purchase', 'created', 'passed'],
    ]);

    const { rows: users } = await t.db.query(
      "SELECT username, role, status, public_key IS NOT NULL AS has_key FROM users WHERE username LIKE 'demo\\_%' ORDER BY username",
    );
    expect(users).toHaveLength(3);
    for (const user of users) {
      expect(user).toMatchObject({ status: 'active', has_key: true });
      expect(user.username).toMatch(/^demo_(miner|transporter|buyer)_[0-9a-f]{6}$/);
    }

    const { rows: steps } = await t.db.query(
      `SELECT s.type, s.review_status, s.anchor_status FROM transactions s JOIN consignments c ON c.id = s.consignment_id
        WHERE c.qr_code = $1 ORDER BY s.received_at`,
      [result.qrCode],
    );
    expect(steps).toEqual([
      { type: 'registration', review_status: 'passed', anchor_status: 'pending' },
      { type: 'handoff', review_status: 'passed', anchor_status: 'pending' },
      { type: 'purchase', review_status: 'passed', anchor_status: 'pending' },
    ]);

    expect(output).toContain(result.qrCode);
    // No key material of any kind in what it prints.
    expect(output).not.toMatch(/PRIVATE|BEGIN|MIG[A-Za-z0-9+/]{20}/);
  });

  it('never touches the seed_* users, whose keys the phone registers later', async () => {
    const seedMiner = await insertUser(t.db, { username: 'seed_miner', role: 'miner', status: 'active' });

    await run();

    const { rows } = await t.db.query('SELECT public_key FROM users WHERE id = $1', [seedMiner.id]);
    expect(rows[0].public_key).toBeNull();
    const { rows: steps } = await t.db.query('SELECT count(*)::int AS n FROM transactions WHERE actor_id = $1', [seedMiner.id]);
    expect(steps[0].n).toBe(0);
  });

  it('audits each account it creates as made by demo-journey', async () => {
    await run();

    const { rows } = await t.db.query(
      "SELECT details FROM audit_logs WHERE action = 'user.create' AND details->>'source' = 'demo-journey'",
    );
    expect(rows.map((r) => r.details.role).sort()).toEqual(['buyer', 'miner', 'transporter']);
  });

  it('uses a new suffix and QR code each run', async () => {
    const first = await run();
    const second = await run();

    expect(second.result.qrCode).not.toBe(first.result.qrCode);
    expect(second.result.users[0].username).not.toBe(first.result.users[0].username);
  });
});
