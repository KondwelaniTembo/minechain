import express from 'express';
import helmet from 'helmet';
import { healthRoutes } from './routes/health.js';
import { notFound } from './middleware/notFound.js';
import { errorHandler } from './middleware/errorHandler.js';

// Builds the app without starting it. server.js passes a real database and listens on a
// port. Tests pass a fake database and hand the app straight to Supertest.
export function createApp({ db }) {
  if (!db || typeof db.query !== 'function') {
    throw new TypeError('createApp needs a db object with a query() method');
  }

  const app = express();

  // Security headers on every response (for example X-Content-Type-Options: nosniff).
  // Helmet also removes X-Powered-By, which would advertise that the server runs Express.
  app.use(helmet());

  // Parses JSON bodies into req.body. The size cap stops a huge body from tying up the
  // server. Real requests (a consignment record) are a few kilobytes.
  app.use(express.json({ limit: '100kb' }));

  app.use('/health', healthRoutes({ db }));

  // Order matters: these two must come after every route.
  app.use(notFound);
  app.use(errorHandler);

  return app;
}
