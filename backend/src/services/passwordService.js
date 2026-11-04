import { randomBytes } from 'node:crypto';
import argon2 from 'argon2';

// OWASP Password Storage Cheat Sheet minimum for Argon2id: 19 MiB of memory, 2 passes,
// 1 thread. Chosen over the library default (64 MiB, t=3, p=4) because Render's free
// instance has 512 MB: ten logins at once need about 190 MB here, but 640 MB at 64 MiB.
// The settings are stored inside every hash, so raising them later is safe; needsRehash
// spots older hashes at login.
export const ARGON2_OPTIONS = Object.freeze({
  type: argon2.argon2id,
  memoryCost: 19456, // KiB
  timeCost: 2,
  parallelism: 1,
  hashLength: 32,
  // The salt is left to the library: 16 fresh random bytes for every hash.
});

// The same-looking text can arrive as different code points, depending on the keyboard
// (for example full-width letters, or e plus a combining accent instead of é). NFKC folds
// them into one form, so the hash depends on what the user meant, not how they typed it.
export function normalizePassword(password) {
  return password.normalize('NFKC');
}

export function createPasswordService({ options = ARGON2_OPTIONS } = {}) {
  // A real hash of a random password, made once and reused. Verifying against it when the
  // username does not exist makes that case cost as much as a wrong password, so response
  // time does not reveal which usernames exist.
  let dummyHash;
  const getDummyHash = () => {
    dummyHash ??= argon2.hash(randomBytes(32).toString('base64url'), options);
    return dummyHash;
  };

  return {
    hash(password) {
      return argon2.hash(normalizePassword(password), options);
    },

    // A malformed stored hash throws rather than returning false: that is a server bug,
    // and it should surface as a 500, not look like a wrong password.
    verify(storedHash, password) {
      return argon2.verify(storedHash, normalizePassword(password));
    },

    // Does the same work as verify, then always answers false.
    async verifyDummy(password) {
      await argon2.verify(await getDummyHash(), normalizePassword(password));
      return false;
    },

    needsRehash(storedHash) {
      return argon2.needsRehash(storedHash, options);
    },
  };
}
