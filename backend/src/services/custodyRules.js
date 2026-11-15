// Where a handoff or purchase may happen, and where it moves the consignment (the contract's
// stage rules, contract spec section 5). Shared by sync, which applies them when a step
// passes its checks, and by the officer's "Clear, no problem", which applies them when a
// flagged step is cleared later (plan B1.2). One copy, so the two can never disagree.
//
// A handoff is allowed from in_transit too, because one journey can have several
// transporters (a relay). A purchase needs a handoff first: there is no direct
// miner-to-buyer sale in the prototype.
export const CUSTODY_RULES = Object.freeze({
  handoff: Object.freeze({ allowedFrom: Object.freeze(['registered', 'in_transit']), to: 'in_transit' }),
  purchase: Object.freeze({ allowedFrom: Object.freeze(['in_transit']), to: 'purchased' }),
});

// The stage a consignment moves to when a step of this type is accepted at currentStage, or
// null when it stays where it is. Forward only:
//   - a registration never moves it (the consignment starts at registered);
//   - a relay (a handoff at in_transit) leaves it at in_transit;
//   - a stage the step is not allowed from leaves it alone. For a cleared step this happens
//     when later steps have already moved the consignment on (a flagged handoff cleared
//     after the purchase), and the stage must never go back.
// Object.hasOwn: a type such as "constructor" must not find something inherited.
export function stageAfter(type, currentStage) {
  if (!Object.hasOwn(CUSTODY_RULES, type)) return null;
  const rule = CUSTODY_RULES[type];
  if (!rule.allowedFrom.includes(currentStage) || rule.to === currentStage) return null;
  return rule.to;
}
