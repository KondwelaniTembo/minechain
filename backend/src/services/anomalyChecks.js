// The anomaly checks run on each stored custody step (FR-08). Each check looks at one
// step and returns either null (nothing wrong) or a finding, which the sync service saves as
// an alert in the same transaction as the step. Any finding makes the step "flagged", and an
// open alert holds the consignment (D3; the duplicate exception is decided on 9 Nov).
//
// The five checks, in the order they run: signature, duplicate consignment, handoff order,
// quantity discrepancy, GPS zone.
//
// Pure: no database, no clock. The sync service gathers everything a check needs into the
// context first. A check whose part of the context is ABSENT (undefined) returns null: it
// was not asked. That is different from present-but-empty, which is an answer: zoneMatch
// for no zones at all flags, baselines with no accepted step finds nothing.
import { ZONE_TOLERANCE_METRES } from './zoneMatch.js';

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

// FR-08: a difference of MORE than this between chain stages is flagged.
export const QUANTITY_THRESHOLD_PERCENT = 10;

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

// A registration for a custody record (QR code) that is already registered. High: someone
// is reusing another consignment's record, or registering the same bag twice.
//
// context.existingRegistration: the consignment's original registration step,
//   { transactionId, actorId, mineral, reviewStatus }; null when the QR code is new.
// The details hold ids only, never names.
export function checkDuplicate({ existingRegistration, step }) {
  if (existingRegistration === undefined || existingRegistration === null) return null;
  if (step?.type !== 'registration') return null;
  return {
    type: 'duplicate_consignment',
    severity: 'high',
    details: {
      originalTransactionId: existingRegistration.transactionId,
      originalReviewStatus: existingRegistration.reviewStatus,
      sameMiner: existingRegistration.actorId === step.actorId,
      mineral: step.mineral,
      originalMineral: existingRegistration.mineral,
    },
  };
}

// A handoff or purchase for a consignment that is already purchased, the final stage.
// A second purchase is high: the same goods sold twice. A handoff is medium: it may be a
// genuine late sync, such as a relay transporter whose phone came online after the buyer's.
// (A purchase while the consignment is still registered is not this rule: sync defers it,
// because its handoff has most likely not arrived yet.)
//
// context.consignmentStage: the consignment's stage before this step.
export function checkHandoffOrder({ consignmentStage, step }) {
  if (consignmentStage === undefined) return null;
  if (consignmentStage !== 'purchased') return null;
  if (step?.type !== 'handoff' && step?.type !== 'purchase') return null;
  return {
    type: 'handoff_order',
    severity: step.type === 'purchase' ? 'high' : 'medium',
    details: { consignmentStage, stepType: step.type },
  };
}

// Weights arrive as text (the payload's weightMg, and weight_mg from pg), and are only ever
// read as BigInt, so no weight is ever a float.
function weightOf(text, name) {
  if (typeof text !== 'string' || !/^[1-9]\d*$/.test(text)) {
    throw new TypeError(`${name} must be a whole number of milligrams above 0, as text`);
  }
  return BigInt(text);
}

// More than 10% off the baseline, in integers only: |w - b| / b > 10/100, multiplied out to
// |w - b| x 100 > b x 10. No division, so nothing is rounded.
function exceedsThreshold(weight, baseline) {
  const difference = weight > baseline ? weight - baseline : baseline - weight;
  return difference * 100n > baseline * BigInt(QUANTITY_THRESHOLD_PERCENT);
}

// A handoff or purchase whose weight is more than 10% off an earlier accepted weight.
// Medium: weighing differs between scales, so an officer judges it.
//
// Two baselines, so gradual loss is caught too ("salami slicing": under 10% at each step,
// but more in total):
//   previous      the latest earlier accepted (passed or cleared) step
//   registration  the consignment's accepted registration, the weight at extraction
// For the first handoff they are the same step, which is then compared once, as the
// registration. Flagged steps are never a baseline: they may be forged.
//
// context.baselines: { previous: { stepId, weightMg } | null, registration: same | null }.
// Either may be null when there is no accepted step of that kind; both null finds nothing.
export function checkQuantity({ baselines, step }) {
  if (baselines === undefined) return null;
  if (step?.type !== 'handoff' && step?.type !== 'purchase') return null;

  const compared = [];
  if (baselines.previous && baselines.previous.stepId !== baselines.registration?.stepId) {
    compared.push(['previous', baselines.previous]);
  }
  if (baselines.registration) compared.push(['registration', baselines.registration]);
  if (compared.length === 0) return null;

  const weight = weightOf(step.weightMg, 'step.weightMg');
  const details = { weightMg: step.weightMg, thresholdPercent: QUANTITY_THRESHOLD_PERCENT, failedBaselines: [] };
  for (const [name, baseline] of compared) {
    const baselineWeight = weightOf(baseline.weightMg, `baselines.${name}.weightMg`);
    const exceeded = exceedsThreshold(weight, baselineWeight);
    // The signed difference, as text: negative is a loss, positive a gain.
    details[name] = { stepId: baseline.stepId, weightMg: baseline.weightMg, differenceMg: (weight - baselineWeight).toString(), exceeded };
    if (exceeded) details.failedBaselines.push(name);
  }
  if (details.failedBaselines.length === 0) return null;
  return { type: 'quantity_discrepancy', severity: 'medium', details };
}

// A registration outside every active GPS zone (FR-08's "unregistered extraction zones").
// Only registrations: extraction happens in a zone, while handoffs happen on the road and
// purchases at buying centres. Sync still records every step's zone_id. Medium: GPS error
// makes false alarms likely, and the 25 m tolerance already absorbs the usual error.
//
// context.zoneMatch: matchZone's result for the step's point among the active zones.
// With no active zones at all, every registration is flagged: none is registered.
export function checkGpsZone({ zoneMatch, step }) {
  if (zoneMatch === undefined) return null;
  if (step?.type !== 'registration') return null;
  if (zoneMatch.zoneId !== null) return null;

  if (zoneMatch.nearestZoneId === null) {
    return { type: 'gps_zone', severity: 'medium', details: { noActiveZones: true, toleranceMetres: ZONE_TOLERANCE_METRES } };
  }
  return {
    type: 'gps_zone',
    severity: 'medium',
    details: {
      nearestZoneId: zoneMatch.nearestZoneId,
      nearestZoneName: zoneMatch.nearestZoneName,
      // Whole metres: the reading is not more precise than that, and this is only shown.
      distanceMetres: Math.round(zoneMatch.distanceMetres),
      toleranceMetres: ZONE_TOLERANCE_METRES,
    },
  };
}

// The checks the sync service runs, in order. Frozen, so nothing can add or remove a check
// at run time; a new check is a code change with its own tests.
export const CHECKS = Object.freeze([checkSignature, checkDuplicate, checkHandoffOrder, checkQuantity, checkGpsZone]);

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

const SEVERITY_RANK = Object.freeze({ high: 3, medium: 2, low: 1 });

// The finding a flagged step's result is named after: the most severe, and among equals the
// first in check order (findings arrive in that order from runChecks). null for none.
export function mostSevereFinding(findings) {
  let chosen = null;
  for (const finding of findings) {
    if (chosen === null || SEVERITY_RANK[finding.severity] > SEVERITY_RANK[chosen.severity]) chosen = finding;
  }
  return chosen;
}

// The sync result code for a flagged step: its most severe finding's type, upper-cased.
export function flaggedCodeFor(findings) {
  const finding = mostSevereFinding(findings);
  return finding === null ? null : finding.type.toUpperCase();
}

// What the app shows for each flagged code, in plain language (NFR-06). Each says the record
// was kept, because the app must not discard or resend it. record_tampered is not here: it
// is raised by verification, never by sync.
export const FLAGGED_MESSAGES = Object.freeze({
  INVALID_SIGNATURE: 'The record was saved, but its signature did not match your device key. An officer will review it.',
  DUPLICATE_CONSIGNMENT: 'This custody record was already registered. Your record was saved, and an officer will review it.',
  HANDOFF_ORDER: 'This consignment has already been sold. Your record was saved, and an officer will review it.',
  QUANTITY_DISCREPANCY: 'The record was saved, but the weight differs by more than 10% from an earlier step. An officer will review it.',
  GPS_ZONE: 'The record was saved, but its location is outside every registered extraction zone. An officer will review it.',
});
