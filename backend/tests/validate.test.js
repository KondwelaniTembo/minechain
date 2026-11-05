import { describe, it, expect } from 'vitest';
import express from 'express';
import request from 'supertest';
import { z } from 'zod';
import { validate } from '../src/middleware/validate.js';
import { errorHandler } from '../src/middleware/errorHandler.js';

// A small schema in the style the auth routes will use: strict, with trimming and a default.
const bodySchema = z
  .object({
    username: z.string().trim().min(3, 'must be at least 3 characters'),
    role: z.enum(['miner', 'transporter', 'buyer']),
    licenceNumber: z.string().trim().optional(),
  })
  .strict();

const querySchema = z.object({ limit: z.coerce.number().int().min(1).max(100).default(20) }).strict();

function appWith(schema, source) {
  const app = express();
  app.use(express.json());
  // Echoes what validate left on req.validated, so the tests can see it.
  app.post('/echo', validate(schema, source), (req, res) => res.json(req.validated));
  app.get('/echo', validate(schema, source), (req, res) => res.json(req.validated));
  app.use(errorHandler);
  return app;
}

describe('validate middleware', () => {
  describe('body', () => {
    const app = appWith(bodySchema);

    it('passes valid data on as req.validated.body, already cleaned up', async () => {
      const res = await request(app).post('/echo').send({ username: '  banda  ', role: 'miner' });

      expect(res.status).toBe(200);
      expect(res.body).toEqual({ body: { username: 'banda', role: 'miner' } });
    });

    it('names each invalid field', async () => {
      const res = await request(app).post('/echo').send({ username: 'jb', role: 'admin' });

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('VALIDATION_FAILED');
      expect(res.body.error.details.map((d) => d.field)).toEqual(['username', 'role']);
      expect(res.body.error.details[0].message).toBe('must be at least 3 characters');
    });

    it('refuses each unknown field by name, so nobody can slip in status or similar', async () => {
      const res = await request(app).post('/echo').send({ username: 'banda', role: 'miner', status: 'active', isAdmin: true });

      expect(res.status).toBe(400);
      expect(res.body.error.details).toEqual([
        { field: 'status', message: 'is not allowed' },
        { field: 'isAdmin', message: 'is not allowed' },
      ]);
    });

    it('reports a missing body as a problem with "body"', async () => {
      const res = await request(app).post('/echo');

      expect(res.status).toBe(400);
      expect(res.body.error.details[0].field).toBe('body');
    });

    it('never echoes the values that were sent', async () => {
      const secretLooking = 'my-secret-licence-value-9876';

      const res = await request(app).post('/echo').send({ username: 'banda', role: 'miner', licenceNumber: 42, extra: secretLooking });

      expect(res.status).toBe(400);
      expect(res.text).not.toContain(secretLooking);
    });
  });

  describe('query', () => {
    const app = appWith(querySchema, 'query');

    it('validates the query string and applies defaults', async () => {
      const res = await request(app).get('/echo');

      expect(res.body).toEqual({ query: { limit: 20 } });
    });

    it('turns a valid query value into its proper type', async () => {
      const res = await request(app).get('/echo?limit=5');

      expect(res.body).toEqual({ query: { limit: 5 } });
    });

    it('refuses an invalid query value', async () => {
      const res = await request(app).get('/echo?limit=500');

      expect(res.status).toBe(400);
      expect(res.body.error.details[0].field).toBe('limit');
    });

    it('names "query", not "body", for a problem with the query as a whole', async () => {
      // A rule on the whole object has an empty path, like a missing body does.
      const needsOneFilter = z
        .object({ from: z.string().optional(), to: z.string().optional() })
        .strict()
        .refine((q) => q.from || q.to, 'give at least one of from or to');

      const res = await request(appWith(needsOneFilter, 'query')).get('/echo');

      expect(res.status).toBe(400);
      expect(res.body.error.details).toEqual([{ field: 'query', message: 'give at least one of from or to' }]);
    });
  });
});
