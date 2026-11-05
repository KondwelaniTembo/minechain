import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { errorHandler } from '../src/middleware/errorHandler.js';
import { AppError } from '../src/errors.js';

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

  describe('AppError', () => {
    function appThatThrows(error) {
      const app = express();
      app.get('/fail', async () => {
        throw error;
      });
      app.use(errorHandler);
      return app;
    }

    it('uses the status, code and message the service chose', async () => {
      const res = await request(appThatThrows(new AppError(409, 'USERNAME_TAKEN', 'That username is already taken.'))).get('/fail');

      expect(res.status).toBe(409);
      expect(res.body).toEqual({ error: { code: 'USERNAME_TAKEN', message: 'That username is already taken.' } });
    });

    it('includes details when there are any', async () => {
      const details = [{ field: 'password', message: 'Use at least 12 characters.' }];

      const res = await request(appThatThrows(new AppError(400, 'VALIDATION_FAILED', 'Some fields are missing or invalid.', details))).get('/fail');

      expect(res.body.error.details).toEqual(details);
    });

    it('is not logged as an unexpected error', async () => {
      await request(appThatThrows(new AppError(401, 'INVALID_CREDENTIALS', 'Username or password is incorrect.'))).get('/fail');

      expect(consoleError).not.toHaveBeenCalled();
    });

    it('is still an Error, with a name and a stack trace for debugging', () => {
      const err = new AppError(403, 'ACCOUNT_NOT_ACTIVE', 'Your account is awaiting approval.');

      expect(err).toBeInstanceOf(Error);
      expect(err.name).toBe('AppError');
      expect(err.stack).toBeDefined();
    });
  });
});
