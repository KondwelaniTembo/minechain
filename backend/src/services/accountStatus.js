import { AppError } from '../errors.js';

// One place for the answer an account gets when it exists and is genuine but is not
// allowed in. Login and requireAuth both use it, so the app sees the same code and message
// wherever the refusal happens. status_reason is never sent: it is for administrators.
const NOT_ACTIVE = {
  pending: { code: 'ACCOUNT_PENDING', message: 'Your account is waiting for approval by an administrator.' },
  suspended: { code: 'ACCOUNT_SUSPENDED', message: 'Your account has been suspended. Please contact an administrator.' },
  rejected: { code: 'ACCOUNT_REJECTED', message: 'Your account request was not approved. Please contact an administrator.' },
};
// A status added later must never be mistaken for active.
const UNKNOWN_STATUS = { code: 'ACCOUNT_NOT_ACTIVE', message: 'Your account is not active. Please contact an administrator.' };

// 403, not 401: we know who this is, and authenticating again would not help.
export function notActiveError(status) {
  const { code, message } = NOT_ACTIVE[status] ?? UNKNOWN_STATUS;
  return new AppError(403, code, message);
}
