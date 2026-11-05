// The five roles, exactly as the users_role_valid CHECK in the users migration allows.
// One list, so a role name used anywhere in the code can be checked against it.
export const ROLES = Object.freeze(['miner', 'transporter', 'buyer', 'officer', 'admin']);
