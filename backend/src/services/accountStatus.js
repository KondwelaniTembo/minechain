import { AppError } from '../errors.js';

// One place for the answer an account gets when it exists and is genuine but is not
// allowed in. Login and requireAuth both use it, so the app sees the same code and message
// wherever the refusal happens. status_reason is never sent: it is for administrators.
const NOT_ACTIVE = {
  pending: { code: 'ACCOUNT_PENDING', message: 'Your account is waiting for approval by an administrator.' },
  suspended: { code: 'ACCOUNT_SUSPENDED', message: 'Your account has been suspended. Please contact an administrator.' },
  rejected: { code: 'ACCOUNT_REJECTED', message: 'Your account request was not approved. Please contact an administrator.' },
  // Created by an administrator, not activated yet. An invited account has no password, so
  // login answers it with the generic 401 before any status is looked at; this entry is for
  // any other path that meets one.
  invited: {
    code: 'ACCOUNT_NOT_ACTIVATED',
    message: 'Your account has not been activated yet. Use the activation code from your administrator.',
  },
  // Deleted by an administrator (B3). Login and requireAuth never get here: a deleted
  // account has no password, so login answers it as an unknown username, and its tokens are
  // refused as TOKEN_INVALID. This entry is for any other path that meets one, such as a key
  // registration whose account was deleted between requireAuth and its own read. The
  // existing ACCOUNT_NOT_ACTIVE code, not a new one: B3 adds only CANNOT_DELETE_SELF.
  deleted: { code: 'ACCOUNT_NOT_ACTIVE', message: 'This account has been deleted. Please contact an administrator.' },
};
// A status added later must never be mistaken for active.
const UNKNOWN_STATUS = { code: 'ACCOUNT_NOT_ACTIVE', message: 'Your account is not active. Please contact an administrator.' };

// 403, not 401: we know who this is, and authenticating again would not help.
export function notActiveError(status) {
  const { code, message } = NOT_ACTIVE[status] ?? UNKNOWN_STATUS;
  return new AppError(403, code, message);
}
