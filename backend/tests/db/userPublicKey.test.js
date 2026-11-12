import { describe, it, expect } from 'vitest';
import { createHash, generateKeyPairSync, randomBytes } from 'node:crypto';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG, MISSING_ID, insertUser } from './fixtures.js';
import { createServices } from '../../src/services/index.js';
import { createUserService } from '../../src/services/userService.js';

const t = useTestDb();

// The real services, as createServices wires them (so the signatures wiring is tested too),
// on the test's own connection.
const users = () => createServices({ db: t.db, config: FAKE_CONFIG }).users;

// Throwaway keys, in memory only.
const newKey = (namedCurve = 'prime256v1') => {
  const { publicKey } = generateKeyPairSync('ec', { namedCurve });
  const der = publicKey.export({ type: 'spki', format: 'der' });
  return { der, base64: der.toString('base64') };
};
const KEY = newKey();
const OTHER_KEY = newKey();
// Computed here, not with the service's code.
const fingerprintOf = (der) => createHash('sha256').update(der).digest('hex');

// TEST-NET-3 (RFC 5737): reserved for documentation, never a real client.
const IP = '203.0.113.9';

const activeUser = (overrides = {}) => insertUser(t.db, { role: 'miner', status: 'active', ...overrides });

async function storedKey(id) {
  const { rows } = await t.db.query('SELECT public_key FROM users WHERE id = $1', [id]);
  return rows[0].public_key;
}

async function keyEntries(id) {
  const { rows } = await t.db.query(
    `SELECT actor_id, action, entity_type, entity_id, details, ip_address
       FROM audit_logs WHERE action = 'user.key_register' AND entity_id = $1 ORDER BY id`,
    [id],
  );
  return rows;
}

// Starts the call inside expect, so the rejection is always handled (the expectRefused
// lesson), then checks nothing was stored or audited.
async function expectRefused(start, expected, user) {
  const before = await storedKey(user.id);
  await expect(start()).rejects.toMatchObject(expected);
  expect(await storedKey(user.id)).toEqual(before);
  expect(await keyEntries(user.id)).toEqual([]);
}

describe('registerPublicKey: the first registration', () => {
  it.each(['miner', 'transporter', 'buyer'])('stores the key of an active %s and returns its fingerprint', async (role) => {
    const user = await activeUser({ role });

    const result = await users().registerPublicKey(user.id, KEY.base64, { ipAddress: IP });

    expect(result).toMatchObject({ id: user.id, role, publicKeyFingerprint: fingerprintOf(KEY.der) });
    expect((await storedKey(user.id)).equals(KEY.der)).toBe(true);
  });

  it('writes one user.key_register entry with the fingerprint, never the key', async () => {
    const user = await activeUser();

    await users().registerPublicKey(user.id, KEY.base64, { ipAddress: IP });

    const entries = await keyEntries(user.id);
    expect(entries).toEqual([
      {
        actor_id: user.id,
        action: 'user.key_register',
        entity_type: 'user',
        entity_id: user.id,
        details: { keyFingerprint: fingerprintOf(KEY.der) },
        ip_address: IP,
      },
    ]);
    const text = JSON.stringify(entries);
    expect(text).not.toContain(KEY.base64);
    expect(text).not.toContain(KEY.der.toString('hex'));
  });

  it('shows the fingerprint on the next authenticated request, and null before', async () => {
    const user = await activeUser();
    expect((await users().getAuthenticatedUser(user.id, 'miner')).publicKeyFingerprint).toBeNull();

    await users().registerPublicKey(user.id, KEY.base64);

    expect((await users().getAuthenticatedUser(user.id, 'miner')).publicKeyFingerprint).toBe(fingerprintOf(KEY.der));
  });

  it('saves nothing when the audit entry cannot be written', async () => {
    const user = await activeUser();
    const failingAudit = {
      record: async () => {
        throw new Error('audit unavailable');
      },
    };
    const service = createUserService({ db: t.db, passwords: {}, passwordPolicy: () => [], audit: failingAudit, tokens: {} });

    await expect(service.registerPublicKey(user.id, KEY.base64)).rejects.toThrow('audit unavailable');

    expect(await storedKey(user.id)).toBeNull();
  });
});

describe('registerPublicKey: a second registration', () => {
  it('accepts the same key again with the same answer and no new audit entry (a retry)', async () => {
    const user = await activeUser();
    const first = await users().registerPublicKey(user.id, KEY.base64);

    const again = await users().registerPublicKey(user.id, KEY.base64);

    expect(again).toEqual(first);
    expect(await keyEntries(user.id)).toHaveLength(1);
  });

  it('refuses a different key with 409 PUBLIC_KEY_ALREADY_REGISTERED and keeps the first', async () => {
    const user = await activeUser();
    await users().registerPublicKey(user.id, KEY.base64);

    await expect(users().registerPublicKey(user.id, OTHER_KEY.base64)).rejects.toMatchObject({
      status: 409,
      code: 'PUBLIC_KEY_ALREADY_REGISTERED',
    });

    expect((await storedKey(user.id)).equals(KEY.der)).toBe(true);
    expect(await keyEntries(user.id)).toHaveLength(1);
  });

  it('refuses a key already on another account with 409 PUBLIC_KEY_IN_USE', async () => {
    const owner = await activeUser();
    const other = await activeUser({ role: 'buyer' });
    await users().registerPublicKey(owner.id, KEY.base64);

    await expectRefused(
      () => users().registerPublicKey(other.id, KEY.base64),
      { status: 409, code: 'PUBLIC_KEY_IN_USE' },
      other,
    );
    // The owner keeps it.
    expect((await storedKey(owner.id)).equals(KEY.der)).toBe(true);
  });
});

describe('registerPublicKey: refusals', () => {
  it.each([
    ['a secp256k1 key', () => newKey('secp256k1').base64],
    ['91 random bytes', () => randomBytes(91).toString('base64')],
    ['base64 without padding', () => KEY.base64.replace(/=+$/, '')],
    ['base64url', () => KEY.der.toString('base64url')],
    ['the key as PEM text', () => generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).publicKey.export({ type: 'spki', format: 'pem' })],
    ['an empty string', () => ''],
  ])('refuses %s with 400 INVALID_PUBLIC_KEY', async (_label, makeKey) => {
    const user = await activeUser();

    await expectRefused(
      () => users().registerPublicKey(user.id, makeKey()),
      { status: 400, code: 'INVALID_PUBLIC_KEY' },
      user,
    );
  });

  it('never repeats the key in the refusal', async () => {
    const user = await activeUser();
    const bad = randomBytes(91).toString('base64');

    const err = await users().registerPublicKey(user.id, bad).then(
      () => null,
      (e) => e,
    );

    expect(err.message).not.toContain(bad);
  });

  it.each(['officer', 'admin'])('refuses an active %s with 403 FORBIDDEN, even without the route', async (role) => {
    const user = await activeUser({ role });

    await expectRefused(
      () => users().registerPublicKey(user.id, KEY.base64),
      { status: 403, code: 'FORBIDDEN' },
      user,
    );
  });

  it.each([
    ['pending', {}, 'ACCOUNT_PENDING'],
    ['suspended', { status_reason: 'Lost device reported' }, 'ACCOUNT_SUSPENDED'],
  ])('refuses a %s account with 403 %s', async (status, extra, code) => {
    const user = await insertUser(t.db, { role: 'miner', status, ...extra });

    await expectRefused(
      () => users().registerPublicKey(user.id, KEY.base64),
      { status: 403, code },
      user,
    );
  });

  it('refuses a user that no longer exists with 401 TOKEN_INVALID', async () => {
    await expect(users().registerPublicKey(MISSING_ID, KEY.base64)).rejects.toMatchObject({
      status: 401,
      code: 'TOKEN_INVALID',
    });
  });
});
