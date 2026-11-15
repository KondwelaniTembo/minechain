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

    it('keeps its own Cache-Control: the path rule below sets no-store only for itself', async () => {
      const res = await request(appThatThrows(new AppError(409, 'USERNAME_TAKEN', 'That username is already taken.'))).get('/fail');

      expect(res.headers['cache-control']).toBeUndefined();
    });

    it('is still an Error, with a name and a stack trace for debugging', () => {
      const err = new AppError(403, 'ACCOUNT_NOT_ACTIVE', 'Your account is awaiting approval.');

      expect(err).toBeInstanceOf(Error);
      expect(err.name).toBe('AppError');
      expect(err.stack).toBeDefined();
    });
  });

  describe('a malformed percent-escape in a route parameter', () => {
    const BAD_VALUE = 'SECRET-LOOKING-VALUE';

    // The real router's error: a plain express app with a parameter route, and a bad escape.
    function appWithParamRoute() {
      const app = express();
      app.get('/items/:id', (req, res) => res.json({ id: req.params.id }));
      app.use(errorHandler);
      return app;
    }

    it('the installed router really throws a URIError with status 400 for it', async () => {
      let seen;
      const app = express();
      app.get('/items/:id', (req, res) => res.json({}));
      app.use((err, req, res, next) => {
        seen = err;
        next(err);
      });
      app.use(errorHandler);

      await request(app).get(`/items/${BAD_VALUE}%E0%A4`);

      expect(seen).toBeInstanceOf(URIError);
      expect(seen.status).toBe(400);
      // The router puts the raw value in the message, which is why it is never logged.
      expect(seen.message).toContain(BAD_VALUE);
    });

    it('answers 400 VALIDATION_FAILED with a fixed message and no-store, echoing nothing, logging nothing', async () => {
      const res = await request(appWithParamRoute()).get(`/items/${BAD_VALUE}%E0%A4`);

      expect(res.status).toBe(400);
      expect(res.body).toEqual({ error: { code: 'VALIDATION_FAILED', message: 'The request path is not valid.' } });
      expect(res.headers['cache-control']).toBe('no-store');
      expect(res.text).not.toContain(BAD_VALUE);
      expect(res.text).not.toContain('%E0');
      expect(consoleError).not.toHaveBeenCalled();
    });

    it('a well-formed escape on the same route still works', async () => {
      const res = await request(appWithParamRoute()).get('/items/a%2Fb');

      expect(res.status).toBe(200);
      expect(res.body).toEqual({ id: 'a/b' });
    });

    function appThatThrows(error) {
      const app = express();
      app.get('/fail', async () => {
        throw error;
      });
      app.use(errorHandler);
      return app;
    }

    it.each([
      ['a URIError with no status (our own code calling decodeURIComponent)', () => new URIError('URI malformed')],
      ['a URIError with another status', () => Object.assign(new URIError('URI malformed'), { status: 500 })],
      ['an ordinary Error with status 400', () => Object.assign(new Error('not a URIError'), { status: 400 })],
    ])('%s keeps the logged 500', async (_label, make) => {
      const res = await request(appThatThrows(make())).get('/fail');

      expect(res.status).toBe(500);
      expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
      expect(consoleError).toHaveBeenCalledWith('Unhandled error:', expect.any(Error));
    });
  });
});
