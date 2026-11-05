import { z } from 'zod';

// Only roles people may request for themselves (FR-12). Officers and administrators are
// created by an administrator (FR-10), so nobody can ask for elevated access through the
// public endpoint.
export const SELF_REGISTER_ROLES = Object.freeze(['miner', 'transporter', 'buyer']);

// Shape checks only. The password policy runs in userService.register, so a weak password
// always gets WEAK_PASSWORD with the policy's codes, wherever the request came from.
// .strict(): any other field, such as status or id, is refused. New accounts are always
// pending; only an administrator can make one active.
export const registerSchema = z
  .object({
    // Same rule as the users_username_format constraint, checked here first so the client
    // gets a field-level message rather than a database error.
    username: z
      .string()
      .trim()
      .min(3, 'must be at least 3 characters')
      .max(32, 'must be at most 32 characters')
      .regex(/^[A-Za-z0-9_.-]+$/, 'may only use letters, digits, and _ . -'),
    fullName: z.string().trim().min(1, 'is required').max(100, 'must be at most 100 characters'),
    // Not trimmed: spaces are a legitimate part of a passphrase.
    password: z.string().min(1, 'is required'),
    role: z.enum(SELF_REGISTER_ROLES, { error: 'must be miner, transporter or buyer' }),
    licenceNumber: z.string().trim().min(1, 'must not be blank').max(50, 'must be at most 50 characters').optional(),
  })
  .strict();
