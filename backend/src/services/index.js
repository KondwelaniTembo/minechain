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
import { createAlertService } from './alertService.js';
import { createConsignmentService } from './consignmentService.js';

// The one place where the real services are connected to each other. server.js and the
// end-to-end DB tests both use it, so the wiring is never written twice. Unit tests skip it
// and pass fakes straight to createApp.
// config comes from loadConfig, so the token secret and lifetime are already validated.
// anchorWorker: the running worker (createAnchorWorkerFromConfig), or null when anchoring
// is off; the admin anchoring status reads its snapshot. clock: for the status's ages.
// chainReader: the key-free reader (createChainReaderFromConfig), or null when the RPC URL or
// contract address is not set; the consignment view's chain checks then report
// chain_unavailable.
export function createServices({ db, config, anchorWorker = null, chainReader = null, clock }) {
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
  const anchoring = createAnchorStatusService({ db, audit, anchorWorker, intervalSeconds: config.anchor?.intervalSeconds, clock });
  // Officers' alert queue and its two closing actions (FR-08, Scope (5)).
  const alerts = createAlertService({ db, audit });
  // The consignment view and its live chain check (FR-04, Scope (9)).
  const consignments = createConsignmentService({ db, chainReader, confirmations: config.anchor?.confirmations });

  return { users, tokens, accounts, signatures, sync, zones, reports, anchoring, alerts, consignments };
}
