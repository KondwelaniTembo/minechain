import { z } from 'zod';

// Only roles people may request for themselves (FR-12). Officers and administrators are
// created by an administrator (FR-10), so nobody can ask for elevated access through the
// public endpoint.
export const SELF_REGISTER_ROLES = Object.freeze(['miner', 'transporter', 'buyer']);

// Same rule as the users_username_format constraint, checked here first so the client
// gets a field-level message rather than a database error. Exported on its own so every
// way of creating a user (registration, the seed script, later FR-10 admin creation)
// applies one rule instead of a copy that could drift.
export const usernameSchema = z
  .string()
  .trim()
  .min(3, 'must be at least 3 characters')
  .max(32, 'must be at most 32 characters')
  .regex(/^[A-Za-z0-9_.-]+$/, 'may only use letters, digits, and _ . -');

// A person's full name, as registration and admin account creation both take it. Exported
// for the same reason as usernameSchema: one rule, never a copy.
export const fullNameSchema = z.string().trim().min(1, 'is required').max(100, 'must be at most 100 characters');

// Shape checks only. The password policy runs in userService.register, so a weak password
// always gets WEAK_PASSWORD with the policy's codes, wherever the request came from.
// .strict(): any other field, such as status or id, is refused. New accounts are always
// pending; only an administrator can make one active.
export const registerSchema = z
  .object({
    username: usernameSchema,
    fullName: fullNameSchema,
    // Not trimmed: spaces are a legitimate part of a passphrase.
    password: z.string().min(1, 'is required'),
    role: z.enum(SELF_REGISTER_ROLES, { error: 'must be miner, transporter or buyer' }),
    licenceNumber: z.string().trim().min(1, 'must not be blank').max(50, 'must be at most 50 characters').optional(),
  })
  .strict();

// PUT /auth/me/public-key. Shape only: the key itself (strict base64, 91 bytes, P-256,
// canonical) is checked by signatureService.parsePublicKey, which knows the real rules.
// Not trimmed: strict base64 refuses whitespace, and quietly trimming would accept text
// that is not exactly what the app produced. 200 is well above the 124 characters a
// 91-byte key takes in base64, and stops a huge string before any decoding.
export const publicKeyBodySchema = z
  .object({
    publicKey: z.string().min(1, 'is required').max(200, 'must be at most 200 characters'),
  })
  .strict();

// Login only checks that both values are present and of a sane size. The password policy
// is not applied: it is for choosing a new password, and applying it here would lock out
// anyone whose password met an older rule.
export const loginSchema = z
  .object({
    // Trimmed and capped like the database rule. Its format is not checked further: a
    // malformed username cannot exist, so authentication answers it with the usual 401.
    username: z.string().trim().min(1, 'is required').max(32, 'must be at most 32 characters'),
    // Not trimmed. The cap stops anyone sending megabytes for Argon2 to work through. It is
    // far above the 128-character registration maximum, so it never refuses a real password.
    password: z.string().min(1, 'is required').max(1024, 'must be at most 1024 characters'),
  })
  .strict();

// POST /auth/me/password. Presence and size only, as at login: the policy on the new
// password runs in userService.changePassword, and the current one is only verified, so an
// older, weaker password can still be replaced. Neither is trimmed (spaces are part of a
// passphrase). The account is the logged-in user, so no id or username is accepted here.
export const changePasswordBodySchema = z
  .object({
    currentPassword: z.string().min(1, 'is required').max(1024, 'must be at most 1024 characters'),
    newPassword: z.string().min(1, 'is required').max(1024, 'must be at most 1024 characters'),
  })
  .strict();

// POST /auth/activate (FR-10). Like login, the schema checks presence and size only.
// - username: as at login. A malformed one cannot be invited, so it gets the usual 401.
// - code: any short string. Whether it can be a code (lower case, hyphens, spaces, O for 0)
//   is decided by activationCode.normalise, the one place that knows the rules; a value it
//   cannot read counts as a wrong guess. 64 is normalise's own limit. Not trimmed, because
//   normalise drops spaces anywhere.
// - password: as at login. The policy runs in userService.activate, which refuses a weak one
//   with WEAK_PASSWORD before the code is looked at.
export const activateBodySchema = z
  .object({
    username: z.string().trim().min(1, 'is required').max(32, 'must be at most 32 characters'),
    code: z.string().min(1, 'is required').max(64, 'must be at most 64 characters'),
    password: z.string().min(1, 'is required').max(1024, 'must be at most 1024 characters'),
  })
  .strict();
