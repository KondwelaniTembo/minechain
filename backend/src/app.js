import express from 'express';
import helmet from 'helmet';
import { healthRoutes } from './routes/health.js';
import { authRoutes } from './routes/auth.js';
import { createRegisterLimiter, createLoginIpLimiter, createLoginUsernameLimiter } from './middleware/rateLimits.js';
import { createRequireAuth } from './middleware/requireAuth.js';
import { notFound } from './middleware/notFound.js';
import { errorHandler } from './middleware/errorHandler.js';

// Builds the app without starting it. server.js passes the real database and services and
// listens on a port. Tests pass fakes and hand the app straight to Supertest.
//
//   trustProxyHops: how many proxies sit in front of the app (config TRUST_PROXY)
//   rateLimits:     { registerPerHour, loginPerIp, loginPerUsername } to override the
//                   limits, for tests
export function createApp({ db, services, trustProxyHops = 0, rateLimits = {} } = {}) {
  if (!db || typeof db.query !== 'function') {
    throw new TypeError('createApp needs a db object with a query() method');
  }
  if (!services?.users) {
    throw new TypeError('createApp needs services.users');
  }
  if (!services.tokens) {
    throw new TypeError('createApp needs services.tokens');
  }

  const app = express();

  // Behind a proxy (Render), every request arrives from the proxy, and the real client is
  // in the X-Forwarded-For header the proxy adds. With N hops, Express trusts the last N
  // entries, so req.ip is the client the proxy saw. Entries a client forged further left
  // are ignored. Rate limits and audit IP addresses both depend on this.
  // Set only when there is a proxy: left at Express's default (false), express-rate-limit
  // can still warn if X-Forwarded-For arrives unexpectedly, a sign TRUST_PROXY is wrong.
  if (trustProxyHops > 0) {
    app.set('trust proxy', trustProxyHops);
  }

  // Security headers on every response (for example X-Content-Type-Options: nosniff).
  // Helmet also removes X-Powered-By, which would advertise that the server runs Express.
  app.use(helmet());

  // Parses JSON bodies into req.body. The size cap stops a huge body from tying up the
  // server. Real requests (a consignment record) are a few kilobytes.
  app.use(express.json({ limit: '100kb' }));

  // Created here, not at import, so every app instance (and every test) counts separately.
  const registerLimiter = createRegisterLimiter({ limit: rateLimits.registerPerHour });
  const loginIpLimiter = createLoginIpLimiter({ limit: rateLimits.loginPerIp });
  const loginUsernameLimiter = createLoginUsernameLimiter({ limit: rateLimits.loginPerUsername });

  app.use('/health', healthRoutes({ db }));
  const requireAuth = createRequireAuth({ tokens: services.tokens, users: services.users });

  app.use('/auth', authRoutes({ users: services.users, registerLimiter, loginIpLimiter, loginUsernameLimiter, requireAuth }));

  // Order matters: these two must come after every route.
  app.use(notFound);
  app.use(errorHandler);

  return app;
}
