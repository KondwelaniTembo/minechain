// What each role may see of one consignment (FR-04; plan §3, "What each role sees", from
// decisions.md Scope (9)). One pure function, the only builder of the consignment view's
// body, so the rules live in one place and can be tested without a database.
//
// Every output field is copied by name from the input. Nothing is spread, so a column the
// service's query gains later (a full name, a licence number, actor_ref, anchor_error) can
// never reach a body unless this file is changed to name it.
//
// Readings settled with the developer before this was built (15 Nov 2026):
//   - A transporter sees no transaction hash before their own handoff: the on-chain event
//     carries the weight, so a public hash would let them read the expected figure on
//     Etherscan and defeat blind measurement. The anchor status and check result still show.
//   - A transporter sees each step's zone name, as a buyer in transit does: Scope (9)'s
//     "no names" means people's names; the zone name reveals no coordinates or weight.
//   - No user id appears anywhere, the viewer's own included; byYou marks the viewer's own
//     steps, and the app knows its own id from /auth/me.
//   - Any handoff this transporter has stored on the consignment counts, whatever its
//     review status: the measurement is recorded, so blindness is no longer at stake.

// The roles that may open the view (the route guard admits only these).
const VIEWER_ROLES = Object.freeze(['transporter', 'buyer', 'officer']);
// Accepted steps: what everyone but an officer is shown.
const ACCEPTED = Object.freeze(['passed', 'cleared']);

// What a role sees, decided once per call from the viewer and the facts.
function permissionsFor(viewer, consignment, facts) {
  switch (viewer.role) {
    case 'officer':
      return { visible: true, allSteps: true, weights: true, gps: true, usernames: true, evidence: true, txHashes: true, review: true };
    case 'buyer': {
      const owns = facts.hasAcceptedPurchase === true;
      // Without an accepted purchase of their own, a buyer may look only while the load is
      // on its way to market. Before that there is nothing to buy; after another buyer's
      // purchase it is not theirs. Either way: not visible, the same 404 as an unknown code.
      const visible = owns || consignment.stage === 'in_transit';
      return { visible, allSteps: false, weights: true, gps: owns, usernames: true, evidence: owns, txHashes: true, review: false };
    }
    case 'transporter': {
      const measured = facts.hasOwnHandoff === true;
      return { visible: true, allSteps: false, weights: measured, gps: false, usernames: false, evidence: false, txHashes: measured, review: false };
    }
    default:
      throw new TypeError('viewer.role must be transporter, buyer or officer');
  }
}

// pg gives timestamptz as a Date; B2.4 may select a time as text instead (B2.2 note).
function timeText(value) {
  if (value instanceof Date) return value.toISOString();
  if (typeof value === 'string') return value;
  throw new TypeError('a time must be a Date or ISO text');
}

const hex = (bytes) => (bytes ? `0x${Buffer.from(bytes).toString('hex')}` : null);
const base64 = (bytes) => Buffer.from(bytes).toString('base64');

function checkFor(step, facts, can) {
  const check = facts.checks.get(step.id);
  // Every listed step must have been checked by the service; a gap is a bug, not a result.
  if (!check) throw new TypeError(`no chain check result for step ${step.id}`);
  const body = { result: check.result };
  // Which fields differ points at what was altered: officers only. Never values.
  if (can.review && check.result === 'mismatch') {
    body.fields = Object.freeze(check.fields.map(String));
    if (check.reason) body.reason = check.reason;
  }
  return Object.freeze(body);
}

function alertsFor(step, facts) {
  const alerts = facts.alerts?.get(step.id) ?? [];
  return Object.freeze(alerts.map((a) => Object.freeze({ id: a.id, type: a.type, status: a.status })));
}

function stepBody(step, viewer, facts, can) {
  const body = {
    id: step.id,
    type: step.type,
    byYou: step.actor_id === viewer.id,
    actor: Object.freeze(can.usernames ? { role: step.actor_role, username: step.actor_username } : { role: step.actor_role }),
  };
  if (can.weights) body.weightMg = step.weight_mg;
  if (can.gps) body.location = Object.freeze({ latitude: step.latitude, longitude: step.longitude });
  // null: outside every active zone when the step was synced.
  body.zoneName = step.zone_name ?? null;
  body.capturedAt = timeText(step.captured_at);
  body.receivedAt = timeText(step.received_at);
  body.anchor = Object.freeze(
    can.txHashes ? { status: step.anchor_status, chainTxHash: hex(step.chain_tx_hash) } : { status: step.anchor_status },
  );
  body.check = checkFor(step, facts, can);
  if (can.review) {
    body.reviewStatus = step.review_status;
    body.alerts = alertsFor(step, facts);
  }
  if (can.evidence) {
    body.evidence = Object.freeze({
      signedPayload: step.signed_payload,
      signature: base64(step.signature),
      signerPublicKey: base64(step.signer_public_key),
    });
  }
  return Object.freeze(body);
}

// viewer:      { id, role } from requireAuth
// consignment: { id, qr_code, mineral_type, stage }
// steps:       every stored step, in custody order, each { id, type, actor_id, actor_role,
//              actor_username, review_status, anchor_status, chain_tx_hash, weight_mg,
//              latitude, longitude, zone_name, captured_at, received_at, signed_payload,
//              signature, signer_public_key }, as pg returns them
// facts:       { held, hasAcceptedPurchase (this buyer), hasOwnHandoff (this transporter),
//              checks: Map step id -> chainCheck result, alerts: Map step id -> [{ id, type,
//              status }] (officers) }
// Returns the body, or null when this viewer may not see the consignment: the service then
// answers 404 CONSIGNMENT_NOT_FOUND, exactly as for an unknown code.
export function discloseConsignment(viewer, consignment, steps, facts) {
  if (!VIEWER_ROLES.includes(viewer?.role)) throw new TypeError('viewer.role must be transporter, buyer or officer');
  const can = permissionsFor(viewer, consignment, facts);
  if (!can.visible) return null;

  const listed = can.allSteps ? steps : steps.filter((s) => ACCEPTED.includes(s.review_status));
  return Object.freeze({
    consignment: Object.freeze({
      id: consignment.id,
      qrCode: consignment.qr_code,
      mineral: consignment.mineral_type,
      stage: consignment.stage,
      // true means "under review": an open alert holds it.
      held: facts.held === true,
      // Tells the app why weights are missing, so it can say "weigh first".
      weightsHidden: !can.weights,
    }),
    steps: Object.freeze(listed.map((step) => stepBody(step, viewer, facts, can))),
  });
}
