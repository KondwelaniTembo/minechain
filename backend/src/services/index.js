import { createPasswordService } from './passwordService.js';
import { checkPasswordPolicy } from './passwordPolicy.js';
import { createAuditService } from './auditService.js';
import { createUserService } from './userService.js';
import { createTokenService } from './tokenService.js';

// The one place where the real services are connected to each other. server.js and the
// end-to-end DB tests both use it, so the wiring is never written twice. Unit tests skip it
// and pass fakes straight to createApp.
// config comes from loadConfig, so the token secret and lifetime are already validated.
export function createServices({ db, config }) {
  const passwords = createPasswordService();
  const audit = createAuditService();
  const tokens = createTokenService({ secret: config.jwtSecret, expiresInSeconds: config.jwtExpiresInSeconds });
  const users = createUserService({ db, passwords, passwordPolicy: checkPasswordPolicy, audit, tokens });

  return { users, tokens };
}
