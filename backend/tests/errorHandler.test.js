import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { errorHandler } from '../src/middleware/errorHandler.js';

// A throwaway app with routes that fail on purpose, so the handler is tested on its own.
function appThatFails() {
  const app = express();
  app.get('/sync-throw', () => {
    throw new Error('password column missing in users table');
  });
  // Express 5 forwards rejected promises to the error handler. Express 4 did not, and the
  // request would hang.
  app.get('/async-throw', async () => {
    throw new Error('password column missing in users table');
  });
  app.use(errorHandler);
  return app;
}

describe('errorHandler', () => {
  let consoleError;

  beforeEach(() => {
    consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it.each(['/sync-throw', '/async-throw'])('turns an unexpected error on %s into a generic 500', async (path) => {
    const res = await request(appThatFails()).get(path);

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
  });

  it('keeps internal details out of the response but logs them', async () => {
    const res = await request(appThatFails()).get('/sync-throw');

    expect(res.text).not.toContain('password column');
    expect(consoleError).toHaveBeenCalledWith('Unhandled error:', expect.any(Error));
  });
});
