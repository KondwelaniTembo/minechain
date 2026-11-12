import { createPasswordService } from './passwordService.js';
import { checkPasswordPolicy } from './passwordPolicy.js';
import { createAuditService } from './auditService.js';
import { createUserService } from './userService.js';
import { createTokenService } from './tokenService.js';
import { createAccountService } from './accountService.js';
import { createSignatureService } from './signatureService.js';
import { createSyncService } from './syncService.js';
import { createZoneService } from './zoneService.js';
import { createReportService } from './reportService.js';
import { createAnchorStatusService } from './anchorStatusService.js';

// The one place where the real services are connected to each other. server.js and the
// end-to-end DB tests both use it, so the wiring is never written twice. Unit tests skip it
// and pass fakes straight to createApp.
// config comes from loadConfig, so the token secret and lifetime are already validated.
// anchorWorker: the running worker (createAnchorWorkerFromConfig), or null when anchoring
// is off; the admin anchoring status reads its snapshot. clock: for the status's ages.
export function createServices({ db, config, anchorWorker = null, clock }) {
  const passwords = createPasswordService();
  const audit = createAuditService();
  const tokens = createTokenService({ secret: config.jwtSecret, expiresInSeconds: config.jwtExpiresInSeconds });
  // Created once and shared: key registration uses it now, and the sync service will use the
  // same instance to verify steps.
  const signatures = createSignatureService();
  const users = createUserService({ db, passwords, passwordPolicy: checkPasswordPolicy, audit, tokens, signatures });
  const accounts = createAccountService({ db, audit });
  const sync = createSyncService({ db, signatures, audit });
  const zones = createZoneService({ db, audit });
  const reports = createReportService({ db, audit });
  const anchoring = createAnchorStatusService({ db, anchorWorker, intervalSeconds: config.anchor?.intervalSeconds, clock });

  return { users, tokens, accounts, signatures, sync, zones, reports, anchoring };
}
