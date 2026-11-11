import { createHash, randomInt, timingSafeEqual } from 'node:crypto';

// Single-use activation codes for officer and admin accounts created by an administrator
// (FR-10). The administrator reads the code out or writes it down once, and the person types
// it on a phone together with their new password. Pure: no database, no HTTP, no logging.
//
// The code is 12 characters of Crockford base32: the digits and capital letters without I, L,
// O and U. I, L and O look like 1, 1 and 0, so they are never generated, and when typed they
// are read as those digits; U is left out so that no accidental words appear. 32 symbols are
// exactly 5 bits each, so 12 characters carry 60 bits: with 5 guesses allowed per code, the
// chance of guessing one is about 4 in 10^18.
//
// Only the SHA-256 of the canonical code is ever stored. A fast hash is enough because the
// code is random, long enough and short-lived; a person's chosen password needs Argon2id
// because people choose guessable ones.
//
// Nothing here puts a code, or what was typed, into an error message or a log.

export const ACTIVATION_CODE_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
export const ACTIVATION_CODE_LENGTH = 12;
export const ACTIVATION_CODE_BITS = 60;

const GROUP_SIZE = 4;
const HASH_BYTES = 32;

// Characters people confuse with digits, read as the digit they look like (Crockford's rule).
const LOOK_ALIKES = Object.freeze({ O: '0', I: '1', L: '1' });

// What may be typed besides the code itself: the hyphens of the display form, and spaces.
const SEPARATORS = /[- ]/g;

// Only plain ASCII letters and digits are looked at. Checked before upper-casing, because
// toUpperCase() maps some other letters onto ASCII ones (the Turkish dotless i, U+0131, becomes 'I',
// which would then be read as 1), and the German sharp s, U+00DF, becomes 'SS', which changes the length.
const ASCII_ALPHANUMERIC = /^[0-9A-Za-z]+$/;

// Far longer than any code with separators; stops very long input before any work is done.
const MAX_INPUT_LENGTH = 64;

// A new code. randomInt draws each character evenly from the 32 symbols; a modulo of random
// bytes would be just as even here (256 is a multiple of 32), but randomInt makes that
// obvious. Never Math.random, which is not a cryptographic generator.
//   code:    the canonical form, as hashed and stored
//   display: the same in groups of four, as shown once to the administrator
export function generate() {
  let code = '';
  for (let i = 0; i < ACTIVATION_CODE_LENGTH; i += 1) code += ACTIVATION_CODE_ALPHABET[randomInt(32)];
  return { code, display: toDisplay(code) };
}

// '7KQ4M2XD9TNE' -> '7KQ4-M2XD-9TNE'.
function toDisplay(code) {
  const groups = [];
  for (let i = 0; i < code.length; i += GROUP_SIZE) groups.push(code.slice(i, i + GROUP_SIZE));
  return groups.join('-');
}

// What was typed, as the canonical 12 characters, or null when it cannot be a code. Accepts
// lower case, hyphens and spaces anywhere, and O, I, L for 0, 1, 1. Anything that is not a
// string gives null, so a caller can pass a request field straight in.
export function normalise(input) {
  if (typeof input !== 'string' || input.length > MAX_INPUT_LENGTH) return null;

  const compact = input.replace(SEPARATORS, '');
  if (!ASCII_ALPHANUMERIC.test(compact)) return null;

  let canonical = '';
  for (const char of compact.toUpperCase()) {
    const read = LOOK_ALIKES[char] ?? char;
    // U, and anything else outside the alphabet, cannot be a code.
    if (!ACTIVATION_CODE_ALPHABET.includes(read)) return null;
    canonical += read;
  }
  return canonical.length === ACTIVATION_CODE_LENGTH ? canonical : null;
}

// The 32-byte SHA-256 of a canonical code, as stored in users.activation_code_hash. Refuses
// anything that is not already canonical, so a caller cannot hash raw input by mistake and
// store a hash that no typed code would ever match.
export function hash(canonical) {
  if (typeof canonical !== 'string' || normalise(canonical) !== canonical) {
    throw new TypeError('activation code hash needs a canonical code; pass it through normalise() first');
  }
  return createHash('sha256').update(canonical, 'utf8').digest();
}

// Whether a typed code's hash equals the stored one. timingSafeEqual compares every byte
// whatever the first difference, so the time taken does not tell an attacker how many
// leading bytes were right. It throws on buffers of different lengths, so anything but two
// 32-byte Buffers is simply false: a missing stored hash (no code issued) never matches.
export function matches(inputHash, storedHash) {
  if (!Buffer.isBuffer(inputHash) || !Buffer.isBuffer(storedHash)) return false;
  if (inputHash.length !== HASH_BYTES || storedHash.length !== HASH_BYTES) return false;
  return timingSafeEqual(inputHash, storedHash);
}
