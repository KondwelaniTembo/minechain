// The anomaly checks run on each stored custody step (FR-08). Each check looks at one
// step and returns either null (nothing wrong) or a finding, which the sync service saves as
// an alert in the same transaction as the step. Any finding makes the step "flagged", and an
// open alert holds the consignment (D3).
//
// Only the signature check exists so far. The others (the 10% quantity check, the GPS zone,
// duplicate consignment and handoff order) are added to CHECKS later, each as one more
// function with the same shape, so the sync service never has to change to run them.
//
// Pure: no database, no clock. The sync service gathers everything a check needs into the
// context first.

// The six types in the alerts_type_valid CHECK in the alerts migration.
export const ALERT_TYPES = Object.freeze([
  'duplicate_consignment',
  'quantity_discrepancy',
  'gps_zone',
  'invalid_signature',
  'handoff_order',
  'record_tampered',
]);
// The alerts_severity_valid CHECK.
export const ALERT_SEVERITIES = Object.freeze(['low', 'medium', 'high']);

// A well-formed step whose signature does not verify against the user's registered key.
// High: the record may have been changed after signing, or signed by another device. The
// fingerprint says which key it was checked against, for the officer reviewing it; the key
// itself never goes into alert details.
//
// context: { verified: boolean, keyFingerprint: string, ... }
export function checkSignature({ verified, keyFingerprint }) {
  if (verified === true) return null;
  return { type: 'invalid_signature', severity: 'high', details: { keyFingerprint } };
}

// The checks the sync service runs, in order. Frozen, so nothing can add or remove a check
// at run time; a new check is a code change with its own tests.
export const CHECKS = Object.freeze([checkSignature]);

// A finding becomes a row in alerts, so it is checked here against the same rules the
// table enforces. A mistake in a new check then fails loudly with a clear message, instead
// of a CHECK violation deep inside the sync transaction.
function assertFinding(finding, checkName) {
  if (!ALERT_TYPES.includes(finding?.type)) {
    throw new TypeError(`${checkName} returned an unknown alert type`);
  }
  if (!ALERT_SEVERITIES.includes(finding.severity)) {
    throw new TypeError(`${checkName} returned an unknown severity`);
  }
  if (finding.details === null || typeof finding.details !== 'object' || Array.isArray(finding.details)) {
    throw new TypeError(`${checkName} must return details as an object`);
  }
}

// Runs every check on one step and returns the findings, in check order. An empty list
// means the step passed. Two findings of the same type are refused: alerts allow one per
// rule per step (UNIQUE (transaction_id, type)).
export function runChecks(context, checks = CHECKS) {
  const findings = [];
  for (const check of checks) {
    const finding = check(context);
    if (finding === null) continue;
    assertFinding(finding, check.name || 'a check');
    if (findings.some((f) => f.type === finding.type)) {
      throw new TypeError(`two checks returned the alert type ${finding.type}`);
    }
    findings.push(finding);
  }
  return findings;
}

// The step's review_status follows from its findings: any finding flags it, so it is held
// for an officer and never anchored until the alert is dismissed.
export function reviewStatusFor(findings) {
  return findings.length > 0 ? 'flagged' : 'passed';
}
