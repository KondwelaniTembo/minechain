import { describe, it, expect, vi, afterEach } from 'vitest';
import argon2 from 'argon2';
import { ARGON2_OPTIONS, createPasswordService, normalizePassword } from '../src/services/passwordService.js';

// Real Argon2 with the real settings (about 50 ms a hash), so these tests prove what
// production does, not a faster stand-in.
const PASSPHRASE = 'gold river kasempa';

afterEach(() => {
  vi.restoreAllMocks();
});

describe('passwordService', () => {
  const service = createPasswordService();

  describe('hash', () => {
    it('produces an Argon2id hash with the OWASP minimum settings', async () => {
      const hash = await service.hash(PASSPHRASE);

      // The encoded string carries the algorithm, version and settings, then salt and hash.
      expect(hash).toMatch(/^\$argon2id\$v=19\$m=19456,t=2,p=1\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+$/);
    });

    it('passes exactly the agreed settings to argon2', async () => {
      const spy = vi.spyOn(argon2, 'hash');

      await service.hash(PASSPHRASE);

      expect(spy).toHaveBeenCalledWith(PASSPHRASE, ARGON2_OPTIONS);
      expect(ARGON2_OPTIONS).toMatchObject({ type: argon2.argon2id, memoryCost: 19456, timeCost: 2, parallelism: 1 });
    });

    it('gives the same password a different hash each time, because of the salt', async () => {
      const first = await service.hash(PASSPHRASE);
      const second = await service.hash(PASSPHRASE);

      expect(first).not.toBe(second);
    });

    it('never contains the password itself', async () => {
      expect(await service.hash(PASSPHRASE)).not.toContain('kasempa');
    });
  });

  describe('verify', () => {
    it('accepts the right password', async () => {
      const hash = await service.hash(PASSPHRASE);

      expect(await service.verify(hash, PASSPHRASE)).toBe(true);
    });

    it.each([
      ['a different word', 'gold river kafue'],
      ['different letter case', 'Gold River Kasempa'],
      ['a missing space', 'gold riverkasempa'],
      ['an empty string', ''],
    ])('refuses %s', async (_label, attempt) => {
      const hash = await service.hash(PASSPHRASE);

      expect(await service.verify(hash, attempt)).toBe(false);
    });

    it('throws on a malformed stored hash instead of pretending the password was wrong', async () => {
      await expect(service.verify('not-a-hash', PASSPHRASE)).rejects.toThrow();
    });
  });

  describe('NFKC normalisation', () => {
    it('treats full-width letters typed on some keyboards as ordinary letters', async () => {
      const hash = await service.hash('ｇｏｌｄ river kasempa'); // full-width "gold"

      expect(await service.verify(hash, PASSPHRASE)).toBe(true);
    });

    it('treats é typed as one character or as e plus an accent the same', async () => {
      const composed = 'café au lait mine';
      const decomposed = 'café au lait mine';
      expect(composed).not.toBe(decomposed);

      const hash = await service.hash(composed);

      expect(await service.verify(hash, decomposed)).toBe(true);
      expect(normalizePassword(decomposed)).toBe(composed);
    });
  });

  describe('verifyDummy', () => {
    it('always answers false, even for the password it was made from', async () => {
      expect(await service.verifyDummy(PASSPHRASE)).toBe(false);
    });

    it('does a real Argon2 verify, so it costs the same as checking a real user', async () => {
      const fresh = createPasswordService();
      const verifySpy = vi.spyOn(argon2, 'verify');

      await fresh.verifyDummy('anything at all here');

      expect(verifySpy).toHaveBeenCalledOnce();
      // The dummy hash uses the same settings as real hashes, so the work is equal.
      expect(verifySpy.mock.calls[0][0]).toMatch(/^\$argon2id\$v=19\$m=19456,t=2,p=1\$/);
    });

    it('makes the dummy hash only once and reuses it', async () => {
      const fresh = createPasswordService();
      const hashSpy = vi.spyOn(argon2, 'hash');

      await fresh.verifyDummy('first attempt here');
      await fresh.verifyDummy('second attempt here');

      expect(hashSpy).toHaveBeenCalledOnce();
    });
  });

  describe('needsRehash', () => {
    it('is false for a hash made with the current settings', async () => {
      expect(service.needsRehash(await service.hash(PASSPHRASE))).toBe(false);
    });

    it('is true for a hash made with weaker, older settings', async () => {
      const older = await argon2.hash(PASSPHRASE, { ...ARGON2_OPTIONS, timeCost: 1 });

      expect(service.needsRehash(older)).toBe(true);
    });
  });
});
