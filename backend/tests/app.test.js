import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';

// Same shape as the object createDb() returns, so the app cannot tell the difference.
function fakeDb() {
  return { query: vi.fn().mockResolvedValue({ rows: [{ '?column?': 1 }], rowCount: 1 }) };
}

// These tests are about the app shell, not registration, so the users service is a stub.
const fakeServices = () => ({ users: { register: vi.fn() } });

// createApp with a fake db unless one is given, mirroring how the old tests called it.
const appWith = (db = fakeDb()) => createApp({ db, services: fakeServices() });

describe('createApp', () => {
  beforeEach(() => {
    // The app logs failures on purpose; keep test output readable.
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('refuses to build without a database', () => {
    expect(() => createApp({ services: fakeServices() })).toThrow(TypeError);
  });

  it('refuses to build without the users service', () => {
    expect(() => createApp({ db: fakeDb() })).toThrow('createApp needs services.users');
  });

  describe('GET /health', () => {
    it('returns 200 when the database answers', async () => {
      const db = fakeDb();

      const res = await request(appWith(db)).get('/health');

      expect(res.status).toBe(200);
      expect(res.body).toEqual({ status: 'ok', database: 'up' });
      expect(db.query).toHaveBeenCalledWith('SELECT 1');
    });

    it('returns 503 without error details when the database is down', async () => {
      const db = fakeDb();
      db.query.mockRejectedValue(new Error('connect ECONNREFUSED 127.0.0.1:5432'));

      const res = await request(appWith(db)).get('/health');

      expect(res.status).toBe(503);
      expect(res.body).toEqual({ status: 'error', database: 'down' });
      expect(res.text).not.toContain('ECONNREFUSED');
    });
  });

  it('sends Helmet security headers and hides X-Powered-By', async () => {
    const res = await request(appWith()).get('/health');

    expect(res.headers['x-content-type-options']).toBe('nosniff');
    expect(res.headers['x-powered-by']).toBeUndefined();
  });

  it('answers unknown routes with a JSON 404', async () => {
    const res = await request(appWith()).get('/no-such-route');

    expect(res.status).toBe(404);
    expect(res.body).toEqual({ error: { code: 'NOT_FOUND', message: 'Route not found' } });
  });

  // express.json() runs before routing, so any path exercises the parser.
  it('rejects malformed JSON with a 400', async () => {
    const res = await request(appWith())
      .post('/health')
      .set('Content-Type', 'application/json')
      .send('{"mineral": "gold",');

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('INVALID_JSON');
  });

  it('rejects a JSON body over 100kb with a 413', async () => {
    const res = await request(appWith())
      .post('/health')
      .send({ padding: 'x'.repeat(150 * 1024) });

    expect(res.status).toBe(413);
    expect(res.body.error.code).toBe('PAYLOAD_TOO_LARGE');
  });
});
