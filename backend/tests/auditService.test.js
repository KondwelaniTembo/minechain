import { describe, it, expect, vi } from 'vitest';
import { createAuditService } from '../src/services/auditService.js';

// A fake db that records the query, so these tests need no database. The real insert is
// covered in tests/db/auditService.test.js.
function fakeDb() {
  return {
    query: vi.fn().mockResolvedValue({ rows: [{ id: '7', occurred_at: new Date('2026-11-05T09:00:00Z') }], rowCount: 1 }),
  };
}

describe('auditService.record', () => {
  const audit = createAuditService();

  it('inserts with parameters and returns the new id and time', async () => {
    const db = fakeDb();

    const result = await audit.record(db, {
      action: 'user.login',
      actorId: 'user-1',
      entityType: 'user',
      entityId: 'user-1',
      details: { method: 'password' },
      ipAddress: '196.46.10.7',
    });

    const [text, params] = db.query.mock.calls[0];
    expect(text).toMatch(/INSERT INTO audit_logs/);
    expect(params).toEqual(['user-1', 'user.login', 'user', 'user-1', '{"method":"password"}', '196.46.10.7']);
    expect(result).toEqual({ id: '7', occurredAt: new Date('2026-11-05T09:00:00Z') });
  });

  it('fills in nulls and empty details for a system entry', async () => {
    const db = fakeDb();

    await audit.record(db, { action: 'system.start' });

    expect(db.query.mock.calls[0][1]).toEqual([null, 'system.start', null, null, '{}', null]);
  });

  it.each([
    ['password', { password: 'gold river kasempa' }],
    ['passwordHash', { passwordHash: '$argon2id$...' }],
    ['token', { token: 'eyJhbGciOi...' }],
    ['refreshToken, nested', { session: { refreshToken: 'abc' } }],
    ['jwtSecret, inside an array', { changes: [{ jwtSecret: 'x' }] }],
  ])('refuses details containing %s, before anything is written', async (key, details) => {
    const db = fakeDb();

    await expect(audit.record(db, { action: 'user.login', details })).rejects.toThrow(TypeError);
    expect(db.query).not.toHaveBeenCalled();
  });

  it('allows ordinary detail keys', async () => {
    const db = fakeDb();

    await audit.record(db, { action: 'user.login_failed', details: { reason: 'wrong_password' } });

    expect(db.query).toHaveBeenCalledOnce();
  });

  it('names the offending key, but never its value', async () => {
    await expect(audit.record(fakeDb(), { action: 'user.login', details: { password: 'gold river kasempa' } })).rejects.toThrow(
      'Audit details must not contain "password"',
    );
  });
});
