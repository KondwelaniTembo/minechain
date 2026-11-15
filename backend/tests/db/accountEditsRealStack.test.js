// Account rename and soft delete through the whole stack (B3.3): a miner made through the API
// signs a step, an administrator renames then deletes the account over HTTP, and afterwards
// the miner's old token and password no longer work while the report still names them.
import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { randomUUID } from 'node:crypto';
import { useTestDb } from './helpers.js';
import { insertUser } from './fixtures.js';
import { auth, bindRealStack, loggedInSigner, stepItem, syncSteps, TEST_PASSPHRASE } from './realStackHelpers.js';
import { ZCAS_CAMPUS_BOUNDARY } from '../../src/seed/seedData.js';

const t = useTestDb();
const { realStack } = bindRealStack(t);

// stepItem captures every step on 2026-11-10, which is the day the report asks for.
const DAY = 'from=2026-11-10&to=2026-11-10';
const NEW_NAME = 'Chanda Mwila';
const REASON = 'Left the cooperative';

const me = (app, token) => auth(request(app).get('/auth/me'), token);
const login = (app, username, password) => request(app).post('/auth/login').send({ username, password });

describe('rename and delete through the real stack', () => {
  it('renames, then deletes a miner: old token and password refused, the report still names them', async () => {
    const { app, tokenFor } = realStack();
    const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
    const adminToken = await tokenFor({ id: admin.id, role: 'admin' });
    const officer = await insertUser(t.db, { role: 'officer', status: 'active' });
    const officerToken = await tokenFor({ id: officer.id, role: 'officer' });
    const zone = await auth(request(app).post('/admin/zones'), adminToken).send({ name: 'ZCAS Campus (edits)', boundary: ZCAS_CAMPUS_BOUNDARY });
    expect(zone.status).toBe(201);

    // A miner through the API: registers, an admin approves, logs in, registers a key. Then
    // one signed registration, so there is history to keep.
    const miner = await loggedInSigner(app, adminToken, 'miner');
    const qrCode = `MC-EDIT-${randomUUID()}`;
    const synced = await syncSteps(app, miner, [stepItem(miner, 'registration', qrCode, { stepId: randomUUID() })]);
    expect(synced.status).toBe(200);
    expect(synced.body.results[0].outcome).toBe('created');

    // ---------- rename ----------
    const renamed = await auth(request(app).post(`/admin/users/${miner.user.id}/rename`), adminToken).send({ fullName: ` ${NEW_NAME} ` });

    expect(renamed.status).toBe(200);
    expect(renamed.headers['cache-control']).toBe('no-store');
    expect(renamed.body.user).toMatchObject({ id: miner.user.id, fullName: NEW_NAME, status: 'active' });
    // A rename ends no session: the miner's token still works and shows the new name.
    const stillIn = await me(app, miner.token);
    expect(stillIn.status).toBe(200);
    expect(stillIn.body.user.fullName).toBe(NEW_NAME);

    // ---------- delete ----------
    const deleted = await auth(request(app).post(`/admin/users/${miner.user.id}/delete`), adminToken).send({ reason: REASON });

    expect(deleted.status).toBe(200);
    expect(deleted.headers['cache-control']).toBe('no-store');
    expect(deleted.body.user).toMatchObject({ id: miner.user.id, status: 'deleted', statusReason: REASON, publicKeyFingerprint: null });

    // The token from the miner's login gets the ordinary "not valid" answer.
    const old = await me(app, miner.token);
    expect(old.status).toBe(401);
    expect(old.body).toEqual({ error: { code: 'TOKEN_INVALID', message: 'Your session is not valid. Please log in again.' } });

    // The right password gets exactly what an unknown username gets.
    const refused = await login(app, miner.username, TEST_PASSPHRASE);
    const unknown = await login(app, 'nobody_by_this_name', TEST_PASSPHRASE);
    expect(refused.status).toBe(401);
    expect(refused.body).toEqual({ error: { code: 'INVALID_CREDENTIALS', message: 'Username or password is incorrect.' } });
    expect(refused.body).toEqual(unknown.body);

    // ---------- history ----------
    const report = await auth(request(app).get(`/reports/transactions?${DAY}`), officerToken);
    expect(report.status).toBe(200);
    expect(report.headers['content-type']).toBe('text/csv; charset=utf-8');
    // Every field is quoted, so the step's row holds both values as whole quoted fields.
    const row = report.text.split('\r\n').find((line) => line.includes(`"${qrCode}"`));
    expect(row).toContain(`"${miner.username}"`);
    expect(row).toContain('"miner"');

    // Both edits recorded against the miner, by the admin, the rename without any name.
    const { rows } = await t.db.query(
      "SELECT actor_id, action, details FROM audit_logs WHERE entity_id = $1 AND action IN ('user.rename', 'user.delete') ORDER BY id",
      [miner.user.id],
    );
    expect(rows).toEqual([
      { actor_id: admin.id, action: 'user.rename', details: { field: 'fullName' } },
      {
        actor_id: admin.id,
        action: 'user.delete',
        details: { from: 'active', to: 'deleted', reason: REASON, keyFingerprint: expect.stringMatching(/^[0-9a-f]{64}$/) },
      },
    ]);
  });
});
