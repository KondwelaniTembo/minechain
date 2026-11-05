import { createPasswordService } from './passwordService.js';
import { checkPasswordPolicy } from './passwordPolicy.js';
import { createAuditService } from './auditService.js';
import { createUserService } from './userService.js';

// The one place where the real services are connected to each other. server.js and the
// end-to-end DB tests both use it, so the wiring is never written twice. Unit tests skip it
// and pass fakes straight to createApp.
export function createServices({ db }) {
  const passwords = createPasswordService();
  const audit = createAuditService();
  const users = createUserService({ db, passwords, passwordPolicy: checkPasswordPolicy, audit });

  return { users };
}
