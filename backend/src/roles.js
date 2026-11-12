// The five roles, exactly as the users_role_valid CHECK in the users migration allows.
// One list, so a role name used anywhere in the code can be checked against it.
export const ROLES = Object.freeze(['miner', 'transporter', 'buyer', 'officer', 'admin']);

// The roles that sign custody steps, and so register a device key (FR-02): the miner
// registers, the transporter takes custody, the buyer purchases. Officers and admins never
// sign a step. This is the same list as SELF_REGISTER_ROLES today, but a separate rule:
// who may request an account and who signs are different questions that could diverge.
export const SIGNING_ROLES = Object.freeze(['miner', 'transporter', 'buyer']);
