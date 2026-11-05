import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { useTestDb } from './helpers.js';
import { createApp } from '../../src/app.js';
import { createServices } from '../../src/services/index.js';
import { FAKE_CONFIG } from './fixtures.js';

const t = useTestDb();

// The whole stack as server.js wires it: Express, the limiter, validation, the controller,
// the real services, Argon2 and PostgreSQL. Only the database connection differs: t.db is
// the test's own connection inside an open transaction, so its ROLLBACK undoes everything.
// Requests are sent one at a time, because a single connection cannot run two at once.
const realApp = () => createApp({ db: t.db, services: createServices({ db: t.db, config: FAKE_CONFIG }) });

const VALID = {
  username: 'mutale_banda',
  fullName: 'Mutale Banda',
  password: 'gold river kasempa',
  role: 'miner',
  licenceNumber: 'ZM-ASM-0042',
};

describe('POST /auth/register through the real stack', () => {
  it('creates a pending user and its audit entry, and returns no secrets', async () => {
    const res = await request(realApp()).post('/auth/register').send(VALID);

    expect(res.status).toBe(201);
    expect(res.body.user).toMatchObject({ username: 'mutale_banda', role: 'miner', status: 'pending' });
    expect(res.text).not.toContain('argon2');
    expect(res.text).not.toContain(VALID.password);

    const { rows: users } = await t.db.query('SELECT * FROM users WHERE id = $1', [res.body.user.id]);
    expect(users).toHaveLength(1);
    expect(users[0].status).toBe('pending');
    expect(users[0].password_hash).toMatch(/^\$argon2id\$/);

    const { rows: entries } = await t.db.query(
      "SELECT * FROM audit_logs WHERE action = 'user.register' AND entity_id = $1",
      [res.body.user.id],
    );
    expect(entries).toHaveLength(1);
    // The client address recorded by Express arrives in the audit log.
    expect(entries[0].ip_address).toMatch(/127\.0\.0\.1|::1/);
  });

  it('answers 409 for the same username in different case, and keeps one account', async () => {
    const app = realApp();
    await request(app).post('/auth/register').send(VALID);

    const res = await request(app)
      .post('/auth/register')
      .send({ ...VALID, username: 'Mutale_Banda', fullName: 'Someone Else' });

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('USERNAME_TAKEN');
    const { rows } = await t.db.query("SELECT count(*)::int AS n FROM users WHERE lower(username) = 'mutale_banda'", []);
    expect(rows[0].n).toBe(1);
  });
});
