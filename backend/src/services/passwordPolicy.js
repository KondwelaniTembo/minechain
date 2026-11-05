import { readFileSync } from 'node:fs';
import { normalizePassword } from './passwordService.js';

// 12 rather than NIST rev. 4's 15 for single-factor passwords: NFR-06 asks for plain, easy
// use by miners with limited English, and a three-word passphrase such as
// "gold river kasempa" meets 12. The blocklist and Argon2's cost make up part of the gap.
export const MIN_PASSWORD_LENGTH = 12;
// Long enough for any passphrase; the cap keeps a huge input from tying up the server.
export const MAX_PASSWORD_LENGTH = 128;

// Loaded once at startup into a Set, so each lookup is instant.
const COMMON_PASSWORDS = new Set(
  readFileSync(new URL('../data/common-passwords.txt', import.meta.url), 'utf8')
    .split(/\r?\n/)
    .filter((line) => line !== '' && !line.startsWith('#')),
);

// Returns a list of problems in plain language; an empty list means the password is
// acceptable. No composition rules (forced digits or symbols), as NIST advises: they make
// passwords harder to remember without making them much harder to guess.
export function checkPasswordPolicy(password, { username } = {}) {
  const normalized = normalizePassword(password);
  // Counted in characters, not UTF-16 units, so an emoji or accented letter counts once.
  const length = [...normalized].length;
  const lower = normalized.toLowerCase();
  const problems = [];

  if (length < MIN_PASSWORD_LENGTH) {
    problems.push({ code: 'PASSWORD_TOO_SHORT', message: `Use at least ${MIN_PASSWORD_LENGTH} characters. A few words with spaces works well.` });
  }
  if (length > MAX_PASSWORD_LENGTH) {
    problems.push({ code: 'PASSWORD_TOO_LONG', message: `Use at most ${MAX_PASSWORD_LENGTH} characters.` });
  }
  if (normalized.trim() === '' || /^(.)\1*$/su.test(normalized)) {
    problems.push({ code: 'PASSWORD_REPEATED', message: 'Do not use one character repeated.' });
  }
  if (username && username.length >= 3 && lower.includes(username.toLowerCase())) {
    problems.push({ code: 'PASSWORD_CONTAINS_USERNAME', message: 'Do not include your username in your password.' });
  }
  if (COMMON_PASSWORDS.has(lower)) {
    problems.push({ code: 'PASSWORD_TOO_COMMON', message: 'This password is too common. Choose something less easy to guess.' });
  }

  return problems;
}
