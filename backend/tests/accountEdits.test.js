import { describe, it, expect } from 'vitest';
import {
  renameRefusal,
  deleteRefusal,
  RENAMABLE_STATUSES,
  DELETABLE_STATUSES,
} from '../src/services/accountService.js';
import { notActiveError } from '../src/services/accountStatus.js';
import { ACCOUNT_STATUSES } from '../src/schemas/adminUsers.js';

// The pure parts of account rename and delete (B3): which statuses each may start from, and
// the whole sentence an administrator reads when one is refused.

describe('which statuses rename and delete start from', () => {
  it('renames pending, invited, active and suspended accounts', () => {
    expect(RENAMABLE_STATUSES).toEqual(['pending', 'invited', 'active', 'suspended']);
  });

  it('deletes active, suspended and invited accounts', () => {
    expect(DELETABLE_STATUSES).toEqual(['active', 'suspended', 'invited']);
  });

  it('decides for every status the database allows', () => {
    // A status added later must be placed on purpose, not fall through by accident.
    for (const status of ACCOUNT_STATUSES) {
      expect(renameRefusal(status) === null).toBe(RENAMABLE_STATUSES.includes(status));
      expect(deleteRefusal(status) === null).toBe(DELETABLE_STATUSES.includes(status));
    }
  });
});

describe('renameRefusal', () => {
  it.each(RENAMABLE_STATUSES)('lets a %s account be renamed', (status) => {
    expect(renameRefusal(status)).toBeNull();
  });

  it.each([
    ['rejected', 'A rejected account cannot be changed.'],
    ['deleted', 'A deleted account cannot be changed.'],
  ])('refuses a %s account with 409', (status, message) => {
    expect(renameRefusal(status)).toMatchObject({ status: 409, code: 'INVALID_STATUS_TRANSITION', message });
  });
});

describe('deleteRefusal', () => {
  it.each(DELETABLE_STATUSES)('lets a %s account be deleted', (status) => {
    expect(deleteRefusal(status)).toBeNull();
  });

  it.each([
    ['pending', 'A pending account cannot be deleted. Reject the request instead, so the person is told why.'],
    ['rejected', 'Only an active, suspended or invited account can be deleted. This account is rejected.'],
    ['deleted', 'This account has already been deleted.'],
  ])('refuses a %s account with 409', (status, message) => {
    expect(deleteRefusal(status)).toMatchObject({ status: 409, code: 'INVALID_STATUS_TRANSITION', message });
  });
});

describe('notActiveError for a deleted account', () => {
  it('answers 403 with the existing ACCOUNT_NOT_ACTIVE code and its own message', () => {
    expect(notActiveError('deleted')).toMatchObject({
      status: 403,
      code: 'ACCOUNT_NOT_ACTIVE',
      message: 'This account has been deleted. Please contact an administrator.',
    });
  });
});
