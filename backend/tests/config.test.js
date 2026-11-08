import { describe, it, expect } from 'vitest';
import { inspect } from 'node:util';
import { loadConfig } from '../src/config.js';

// Fake values only. Each test overrides just the variable it is about, so a failure
// points at a single rule.
const validEnv = {
  NODE_ENV: 'development',
  PORT: '3000',
  DATABASE_URL: 'postgresql://user:pass@localhost:5432/minechain_dev',
  TEST_DATABASE_URL: 'postgresql://user:pass@localhost:5432/minechain_test',
  // Exactly 43 characters, the minimum.
  JWT_SECRET: 'a-fake-test-secret-that-is-long-enough-1234',
  JWT_EXPIRES_IN: '60m',
};

const withEnv = (overrides) => ({ ...validEnv, ...overrides });

// What config.anchor holds when no anchoring variable is set. The secrets are
// non-enumerable, so toEqual does not see them; their own tests below read them by name.
const ANCHOR_DEFAULTS = {
  enabled: false,
  chainId: 11155111n,
  contractAddress: null,
  intervalSeconds: 30,
  confirmations: 2,
  maxAttempts: 5,
  lowBalanceWei: 2_000_000_000_000_000n, // 0.002 ETH
  maxFeePerGasWei: 50_000_000_000n, // 50 gwei
};

// Fake chain settings. The key is a made-up number, not any real wallet's, and the URLs use
// the reserved .example domain. Each one is distinctive so the leak tests can search for it.
const FAKE_RPC_URL = 'https://sepolia.rpc.example/v2/fake-primary-api-key-1234';
const FAKE_FALLBACK_URL = 'https://fallback.rpc.example/fake-fallback-api-key-5678';
const FAKE_PRIVATE_KEY = `0x${'1a2b3c4d'.repeat(8)}`;
const CONTRACT_ADDRESS = '0x6419cB5268706E2aA4713AB3bCFc336248Ed158a';

const anchorEnv = {
  ANCHOR_ENABLED: 'true',
  SEPOLIA_RPC_URL: FAKE_RPC_URL,
  SEPOLIA_RPC_URL_FALLBACK: FAKE_FALLBACK_URL,
  MINECHAIN_CONTRACT_ADDRESS: CONTRACT_ADDRESS,
  RECORDER_PRIVATE_KEY: FAKE_PRIVATE_KEY,
};

// The same placeholders as backend/.env.example.
const PLACEHOLDERS = {
  SEPOLIA_RPC_URL: 'https://replace-with-your-sepolia-rpc-url',
  SEPOLIA_RPC_URL_FALLBACK: 'https://replace-with-a-second-sepolia-rpc-url',
  RECORDER_PRIVATE_KEY: 'replace-with-0x-and-64-hex-characters',
};

const withAnchor = (overrides = {}) => withEnv({ ...anchorEnv, ...overrides });

describe('loadConfig', () => {
  it('returns typed values from a valid environment', () => {
    const config = loadConfig(validEnv);

    expect(config).toEqual({
      nodeEnv: 'development',
      port: 3000,
      databaseUrl: validEnv.DATABASE_URL,
      jwtSecret: validEnv.JWT_SECRET,
      jwtExpiresInSeconds: 3600,
      trustProxyHops: 0,
      anchor: ANCHOR_DEFAULTS,
    });
    expect(Object.isFrozen(config)).toBe(true);
  });

  it('defaults NODE_ENV and PORT when they are missing', () => {
    const { NODE_ENV, PORT, ...rest } = validEnv;

    const config = loadConfig(rest);

    expect(config.nodeEnv).toBe('development');
    expect(config.port).toBe(3000);
  });

  it.each([
    ['30s', 30],
    ['15m', 900],
    ['1h', 3600],
  ])('converts JWT_EXPIRES_IN=%s to %i seconds', (value, seconds) => {
    expect(loadConfig(withEnv({ JWT_EXPIRES_IN: value })).jwtExpiresInSeconds).toBe(seconds);
  });

  it.each(['61m', '2h', '3601s', '0m'])('rejects token lifetime %s (NFR-01)', (value) => {
    expect(() => loadConfig(withEnv({ JWT_EXPIRES_IN: value }))).toThrow(/JWT_EXPIRES_IN/);
  });

  it.each(['60', '1d', 'sixty minutes', ''])('rejects badly formatted lifetime "%s"', (value) => {
    expect(() => loadConfig(withEnv({ JWT_EXPIRES_IN: value }))).toThrow(/JWT_EXPIRES_IN/);
  });

  it('accepts a JWT_SECRET of exactly 43 characters', () => {
    expect(validEnv.JWT_SECRET).toHaveLength(43);
    expect(loadConfig(validEnv).jwtSecret).toBe(validEnv.JWT_SECRET);
  });

  it('rejects a JWT_SECRET of 42 characters', () => {
    const secret = 'x'.repeat(42);

    expect(() => loadConfig(withEnv({ JWT_SECRET: secret }))).toThrow(/JWT_SECRET: must be at least 43/);
  });

  it('accepts a secret made by the generator in .env.example (64 characters)', () => {
    // randomBytes(48).toString('base64url') always gives 64 characters.
    const secret = 'Zx9'.repeat(21) + 'Q';

    expect(loadConfig(withEnv({ JWT_SECRET: secret })).jwtSecret).toHaveLength(64);
  });

  it('rejects the placeholder secret from .env.example', () => {
    const placeholder = 'replace-with-at-least-43-random-characters-xxxxxxxxxxxx';

    expect(() => loadConfig(withEnv({ JWT_SECRET: placeholder }))).toThrow(/placeholder/);
  });

  describe('TRUST_PROXY', () => {
    it('defaults to 0 proxies', () => {
      expect(loadConfig(validEnv).trustProxyHops).toBe(0);
    });

    it.each([
      ['0', 0],
      ['1', 1],
    ])('turns TRUST_PROXY=%s into %i', (value, hops) => {
      expect(loadConfig(withEnv({ TRUST_PROXY: value })).trustProxyHops).toBe(hops);
    });

    it.each(['-1', '6', '1.5', 'true'])('rejects TRUST_PROXY=%s', (value) => {
      expect(() => loadConfig(withEnv({ TRUST_PROXY: value }))).toThrow(/TRUST_PROXY/);
    });
  });

  it('rejects a DATABASE_URL that is not a PostgreSQL connection string', () => {
    expect(() => loadConfig(withEnv({ DATABASE_URL: 'mysql://localhost/db' }))).toThrow(/DATABASE_URL/);
  });

  it('rejects an invalid PORT', () => {
    expect(() => loadConfig(withEnv({ PORT: '70000' }))).toThrow(/PORT/);
  });

  it('lists every problem at once, not just the first', () => {
    const { DATABASE_URL, JWT_SECRET, ...rest } = validEnv;

    expect(() => loadConfig(rest)).toThrow(/DATABASE_URL[\s\S]*JWT_SECRET/);
  });

  it('never puts secret values in the error message', () => {
    const secret = 'replace-with-this-should-not-appear-in-the-logs';

    expect(() => loadConfig(withEnv({ JWT_SECRET: secret }))).toThrow(
      expect.objectContaining({ message: expect.not.stringContaining(secret) }),
    );
  });

  describe('when NODE_ENV is test', () => {
    it('uses TEST_DATABASE_URL instead of DATABASE_URL', () => {
      const config = loadConfig(withEnv({ NODE_ENV: 'test' }));

      expect(config.databaseUrl).toBe(validEnv.TEST_DATABASE_URL);
    });

    it('requires TEST_DATABASE_URL', () => {
      const { TEST_DATABASE_URL, ...rest } = withEnv({ NODE_ENV: 'test' });

      expect(() => loadConfig(rest)).toThrow(/TEST_DATABASE_URL: is required/);
    });

    it('refuses a test database that is the development database', () => {
      const env = withEnv({ NODE_ENV: 'test', TEST_DATABASE_URL: validEnv.DATABASE_URL });

      expect(() => loadConfig(env)).toThrow(/TEST_DATABASE_URL: must differ/);
    });
  });

  describe('anchoring settings', () => {
    describe('ANCHOR_ENABLED', () => {
      it('is off by default, and the API starts with no chain settings at all', () => {
        const config = loadConfig(validEnv);

        expect(config.anchor).toEqual(ANCHOR_DEFAULTS);
        expect(config.anchor.rpcUrl).toBeNull();
        expect(config.anchor.fallbackRpcUrl).toBeNull();
        expect(config.anchor.recorderPrivateKey).toBeNull();
      });

      it('treats the text "false" as off (z.coerce.boolean would make it true)', () => {
        expect(loadConfig(withEnv({ ANCHOR_ENABLED: 'false' })).anchor.enabled).toBe(false);
      });

      it('treats an empty value as off', () => {
        expect(loadConfig(withEnv({ ANCHOR_ENABLED: '' })).anchor.enabled).toBe(false);
      });

      it('turns on with "true" when every required setting is present', () => {
        const { anchor } = loadConfig(withAnchor());

        expect(anchor.enabled).toBe(true);
        expect(anchor.contractAddress).toBe(CONTRACT_ADDRESS);
        expect(anchor.rpcUrl).toBe(FAKE_RPC_URL);
        expect(anchor.fallbackRpcUrl).toBe(FAKE_FALLBACK_URL);
        expect(anchor.recorderPrivateKey).toBe(FAKE_PRIVATE_KEY);
      });

      it.each(['TRUE', 'True', '1', 'yes', 'on', '0', 'no'])('rejects ANCHOR_ENABLED=%s', (value) => {
        expect(() => loadConfig(withEnv({ ANCHOR_ENABLED: value }))).toThrow(/ANCHOR_ENABLED: must be true or false/);
      });
    });

    describe('while anchoring is off', () => {
      it('starts with the three secrets empty, as "NAME=" lines in .env', () => {
        const env = withEnv({ SEPOLIA_RPC_URL: '', SEPOLIA_RPC_URL_FALLBACK: '', RECORDER_PRIVATE_KEY: '' });

        expect(loadConfig(env).anchor.recorderPrivateKey).toBeNull();
      });

      it('starts with a copied .env.example, placeholders and all', () => {
        const config = loadConfig(withEnv({ ...PLACEHOLDERS, ANCHOR_ENABLED: 'false' }));

        expect(config.anchor.rpcUrl).toBeNull();
        expect(config.anchor.fallbackRpcUrl).toBeNull();
        expect(config.anchor.recorderPrivateKey).toBeNull();
      });

      it('still refuses a value that is filled in but wrong', () => {
        // A typo should surface now, not on the day anchoring is switched on.
        expect(() => loadConfig(withEnv({ RECORDER_PRIVATE_KEY: '0x1234' }))).toThrow(/RECORDER_PRIVATE_KEY/);
      });
    });

    describe('while anchoring is on', () => {
      it.each(['SEPOLIA_RPC_URL', 'MINECHAIN_CONTRACT_ADDRESS', 'RECORDER_PRIVATE_KEY'])('requires %s', (key) => {
        const { [key]: _left, ...rest } = withAnchor();

        expect(() => loadConfig(rest)).toThrow(new RegExp(`${key}: is required when ANCHOR_ENABLED is true`));
      });

      it.each(['SEPOLIA_RPC_URL', 'MINECHAIN_CONTRACT_ADDRESS', 'RECORDER_PRIVATE_KEY'])(
        'counts an empty %s as missing',
        (key) => {
          expect(() => loadConfig(withAnchor({ [key]: '' }))).toThrow(new RegExp(`${key}: is required`));
        },
      );

      it('does not require the fallback URL', () => {
        const { SEPOLIA_RPC_URL_FALLBACK, ...rest } = withAnchor();

        expect(loadConfig(rest).anchor.fallbackRpcUrl).toBeNull();
      });

      it.each(Object.keys(PLACEHOLDERS))('refuses the .env.example placeholder in %s', (key) => {
        expect(() => loadConfig(withAnchor({ [key]: PLACEHOLDERS[key] }))).toThrow(
          new RegExp(`${key}: still holds the .env.example placeholder`),
        );
      });
    });

    describe('RPC URLs', () => {
      it.each(['SEPOLIA_RPC_URL', 'SEPOLIA_RPC_URL_FALLBACK'])('%s must use https', (key) => {
        const env = withAnchor({ [key]: 'http://sepolia.rpc.example/v2/key' });

        expect(() => loadConfig(env)).toThrow(new RegExp(`${key}: must start with https://`));
      });

      it.each(['SEPOLIA_RPC_URL', 'SEPOLIA_RPC_URL_FALLBACK'])('%s must be a full URL', (key) => {
        expect(() => loadConfig(withAnchor({ [key]: 'sepolia.rpc.example' }))).toThrow(
          new RegExp(`${key}: must be a full URL`),
        );
      });

      it('refuses a fallback that is the primary again', () => {
        const env = withAnchor({ SEPOLIA_RPC_URL_FALLBACK: FAKE_RPC_URL });

        expect(() => loadConfig(env)).toThrow(/SEPOLIA_RPC_URL_FALLBACK: must differ from SEPOLIA_RPC_URL/);
      });

      it.each([
        ['an invalid primary', { SEPOLIA_RPC_URL: 'not a url fake-primary-api-key-1234' }],
        ['an invalid fallback', { SEPOLIA_RPC_URL_FALLBACK: 'not a url fake-fallback-api-key-5678' }],
        [
          'both invalid and identical',
          { SEPOLIA_RPC_URL: 'not a url fake-api-key-9999', SEPOLIA_RPC_URL_FALLBACK: 'not a url fake-api-key-9999' },
        ],
      ])('%s only ever gives our configuration error, never a raw URL error', (_label, overrides) => {
        let thrown;
        try {
          loadConfig(withAnchor(overrides));
        } catch (err) {
          thrown = err;
        }

        // Node's own TypeError would say "Invalid URL" and carry the raw value in err.input.
        expect(thrown).toBeInstanceOf(Error);
        expect(thrown).not.toBeInstanceOf(TypeError);
        expect(thrown.message).toMatch(/^Invalid environment configuration:/);
        expect(thrown.message).toMatch(/must be a full URL/);
        expect(thrown.input).toBeUndefined();
        for (const value of Object.values(overrides)) {
          expect(thrown.message).not.toContain(value);
        }
      });

      it('compares them as URLs, so a trailing slash does not make them different', () => {
        const env = withAnchor({
          SEPOLIA_RPC_URL: 'https://same.rpc.example',
          SEPOLIA_RPC_URL_FALLBACK: 'https://same.rpc.example/',
        });

        expect(() => loadConfig(env)).toThrow(/SEPOLIA_RPC_URL_FALLBACK: must differ/);
      });
    });

    describe('MINECHAIN_CONTRACT_ADDRESS', () => {
      it('accepts the deployed address in its checksummed form', () => {
        expect(loadConfig(withAnchor()).anchor.contractAddress).toBe(CONTRACT_ADDRESS);
      });

      it('refuses the all-lower-case form, which carries no checksum', () => {
        const env = withAnchor({ MINECHAIN_CONTRACT_ADDRESS: CONTRACT_ADDRESS.toLowerCase() });

        expect(() => loadConfig(env)).toThrow(/MINECHAIN_CONTRACT_ADDRESS: must be in checksummed mixed case/);
      });

      it('refuses a mixed-case address whose checksum is wrong (one letter changed case)', () => {
        const typo = CONTRACT_ADDRESS.replace('cB52', 'cb52');

        expect(() => loadConfig(withAnchor({ MINECHAIN_CONTRACT_ADDRESS: typo }))).toThrow(
          /MINECHAIN_CONTRACT_ADDRESS: has a wrong checksum/,
        );
      });

      it.each([
        ['too short', '0x6419cB5268706E2aA4713AB3bCFc336248Ed158'],
        ['no 0x', '6419cB5268706E2aA4713AB3bCFc336248Ed158a1'],
        ['not hex', '0x6419cB5268706E2aA4713AB3bCFc336248Ed158g'],
      ])('refuses an address that is %s', (_label, value) => {
        expect(() => loadConfig(withAnchor({ MINECHAIN_CONTRACT_ADDRESS: value }))).toThrow(
          /MINECHAIN_CONTRACT_ADDRESS: must be 0x followed by 40 hex characters/,
        );
      });

      it('refuses the zero address', () => {
        const env = withAnchor({ MINECHAIN_CONTRACT_ADDRESS: `0x${'0'.repeat(40)}` });

        expect(() => loadConfig(env)).toThrow(/MINECHAIN_CONTRACT_ADDRESS: must not be the zero address/);
      });
    });

    describe('RECORDER_PRIVATE_KEY', () => {
      it.each([
        ['without 0x', '1a2b3c4d'.repeat(8)],
        ['63 hex characters', `0x${'a'.repeat(63)}`],
        ['65 hex characters', `0x${'a'.repeat(65)}`],
        ['not hex', `0x${'g'.repeat(64)}`],
      ])('refuses a key %s', (_label, value) => {
        expect(() => loadConfig(withAnchor({ RECORDER_PRIVATE_KEY: value }))).toThrow(
          /RECORDER_PRIVATE_KEY: must be 0x followed by 64 hex characters/,
        );
      });

      it('refuses zero', () => {
        expect(() => loadConfig(withAnchor({ RECORDER_PRIVATE_KEY: `0x${'0'.repeat(64)}` }))).toThrow(
          /RECORDER_PRIVATE_KEY: must not be zero/,
        );
      });

      it.each([
        ['the curve order n itself', '0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141'],
        ['all f', `0x${'f'.repeat(64)}`],
      ])('refuses %s, which is not a usable key', (_label, value) => {
        expect(() => loadConfig(withAnchor({ RECORDER_PRIVATE_KEY: value }))).toThrow(
          /RECORDER_PRIVATE_KEY: is not a valid secp256k1 private key/,
        );
      });

      it('accepts n - 1, the largest valid key', () => {
        const largest = '0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140';

        expect(loadConfig(withAnchor({ RECORDER_PRIVATE_KEY: largest })).anchor.recorderPrivateKey).toBe(largest);
      });
    });

    describe('CHAIN_ID', () => {
      it('defaults to Sepolia as a bigint', () => {
        expect(loadConfig(withAnchor()).anchor.chainId).toBe(11155111n);
      });

      it('accepts 11155111 written out', () => {
        expect(loadConfig(withAnchor({ CHAIN_ID: '11155111' })).anchor.chainId).toBe(11155111n);
      });

      it.each(['1', '31337', '11155112'])('refuses CHAIN_ID=%s, which is not Sepolia', (value) => {
        expect(() => loadConfig(withAnchor({ CHAIN_ID: value }))).toThrow(/CHAIN_ID: must be 11155111 \(Sepolia\)/);
      });

      it.each(['abc', '11155111.0', '-1', '0x aa36a7'])('refuses CHAIN_ID=%s without crashing', (value) => {
        // Checks that the BigInt conversion never runs on bad text, where it would throw a
        // SyntaxError instead of giving a normal configuration error.
        expect(() => loadConfig(withAnchor({ CHAIN_ID: value }))).toThrow(/Invalid environment configuration/);
      });
    });

    describe('whole-number settings', () => {
      it.each([
        ['ANCHOR_INTERVAL_SECONDS', 'intervalSeconds', '5', 5],
        ['ANCHOR_INTERVAL_SECONDS', 'intervalSeconds', '3600', 3600],
        ['ANCHOR_CONFIRMATIONS', 'confirmations', '1', 1],
        ['ANCHOR_CONFIRMATIONS', 'confirmations', '12', 12],
        ['ANCHOR_MAX_ATTEMPTS', 'maxAttempts', '1', 1],
        ['ANCHOR_MAX_ATTEMPTS', 'maxAttempts', '20', 20],
      ])('accepts %s=%s', (key, field, value, expected) => {
        expect(loadConfig(withAnchor({ [key]: value })).anchor[field]).toBe(expected);
      });

      it.each([
        ['ANCHOR_INTERVAL_SECONDS', '4'],
        ['ANCHOR_INTERVAL_SECONDS', '3601'],
        ['ANCHOR_INTERVAL_SECONDS', '1.5'],
        ['ANCHOR_CONFIRMATIONS', '0'],
        ['ANCHOR_CONFIRMATIONS', '13'],
        ['ANCHOR_MAX_ATTEMPTS', '0'],
        ['ANCHOR_MAX_ATTEMPTS', '21'],
        ['ANCHOR_MAX_ATTEMPTS', 'five'],
      ])('refuses %s=%s', (key, value) => {
        expect(() => loadConfig(withAnchor({ [key]: value }))).toThrow(new RegExp(`${key}:`));
      });

      it('uses the default for an empty value', () => {
        expect(loadConfig(withAnchor({ ANCHOR_INTERVAL_SECONDS: '' })).anchor.intervalSeconds).toBe(30);
      });
    });

    describe('decimal amounts, converted with BigInt and never through a float', () => {
      it.each([
        ['0.002', 2_000_000_000_000_000n],
        ['1', 1_000_000_000_000_000_000n],
        ['0.1', 100_000_000_000_000_000n],
        ['0.000000000000000001', 1n],
        ['0', 0n],
      ])('ANCHOR_LOW_BALANCE_ETH=%s is %s wei', (value, wei) => {
        expect(loadConfig(withAnchor({ ANCHOR_LOW_BALANCE_ETH: value })).anchor.lowBalanceWei).toBe(wei);
      });

      it.each([
        ['50', 50_000_000_000n],
        ['0.5', 500_000_000n],
        ['0.000000001', 1n],
      ])('ANCHOR_MAX_FEE_GWEI=%s is %s wei', (value, wei) => {
        expect(loadConfig(withAnchor({ ANCHOR_MAX_FEE_GWEI: value })).anchor.maxFeePerGasWei).toBe(wei);
      });

      it.each([
        ['ANCHOR_LOW_BALANCE_ETH', '1e-3'],
        ['ANCHOR_LOW_BALANCE_ETH', '-1'],
        ['ANCHOR_LOW_BALANCE_ETH', '.5'],
        ['ANCHOR_LOW_BALANCE_ETH', '5.'],
        ['ANCHOR_LOW_BALANCE_ETH', '0,5'],
        ['ANCHOR_LOW_BALANCE_ETH', ' 1'],
        // 19 decimal places: finer than 1 wei, so it cannot be stored exactly.
        ['ANCHOR_LOW_BALANCE_ETH', '0.0000000000000000001'],
        // 10 decimal places: finer than 1 wei for gwei.
        ['ANCHOR_MAX_FEE_GWEI', '0.0000000001'],
        ['ANCHOR_MAX_FEE_GWEI', 'fifty'],
      ])('refuses %s=%s', (key, value) => {
        expect(() => loadConfig(withAnchor({ [key]: value }))).toThrow(new RegExp(`${key}: must be a decimal number`));
      });

      it.each(['0', '0.0', '0.000000000'])('refuses ANCHOR_MAX_FEE_GWEI=%s, which would stop every send', (value) => {
        expect(() => loadConfig(withAnchor({ ANCHOR_MAX_FEE_GWEI: value }))).toThrow(
          /ANCHOR_MAX_FEE_GWEI: must be more than 0/,
        );
      });
    });

    describe('keeping the secrets out of sight', () => {
      const SECRETS = [FAKE_PRIVATE_KEY, FAKE_RPC_URL, FAKE_FALLBACK_URL];
      // Also the distinctive parts, in case a tool reformats a URL.
      const FRAGMENTS = ['1a2b3c4d', 'fake-primary-api-key', 'fake-fallback-api-key'];

      function expectNoSecretsIn(text) {
        for (const secret of [...SECRETS, ...FRAGMENTS]) {
          expect(text).not.toContain(secret);
        }
      }

      it('JSON.stringify never shows them', () => {
        // JSON.stringify cannot handle bigint, so this replacer stands in for what a logger does.
        const text = JSON.stringify(loadConfig(withAnchor()), (_key, value) =>
          typeof value === 'bigint' ? value.toString() : value,
        );

        expectNoSecretsIn(text);
      });

      it('util.inspect (what console.log uses) never shows them, even with showHidden', () => {
        const config = loadConfig(withAnchor());

        expectNoSecretsIn(inspect(config, { depth: null }));
        expectNoSecretsIn(inspect(config, { depth: null, showHidden: true }));
      });

      it('they are not enumerable keys, so a spread copy leaves them out too', () => {
        const { anchor } = loadConfig(withAnchor());

        for (const name of ['rpcUrl', 'fallbackRpcUrl', 'recorderPrivateKey']) {
          expect(Object.keys(anchor)).not.toContain(name);
          expect({ ...anchor }).not.toHaveProperty(name);
        }
      });

      it('the anchoring config is frozen, so a secret cannot be swapped at runtime', () => {
        const { anchor } = loadConfig(withAnchor());

        expect(Object.isFrozen(anchor)).toBe(true);
        expect(() => {
          anchor.recorderPrivateKey = `0x${'2'.repeat(64)}`;
        }).toThrow(TypeError);
        expect(anchor.recorderPrivateKey).toBe(FAKE_PRIVATE_KEY);
      });

      it.each([
        ['RECORDER_PRIVATE_KEY', `0x${'1a2b3c4d'.repeat(7)}zzzzzzzz`],
        ['SEPOLIA_RPC_URL', 'http://sepolia.rpc.example/v2/fake-primary-api-key-1234'],
        ['SEPOLIA_RPC_URL_FALLBACK', 'fallback.rpc.example/fake-fallback-api-key-5678'],
        // A wrong checksum: ethers' own error message would repeat the address.
        ['MINECHAIN_CONTRACT_ADDRESS', '0x6419cb5268706E2aA4713AB3bCFc336248Ed158a'],
      ])('the error for a bad %s names the variable but not the value', (key, value) => {
        let message;
        try {
          loadConfig(withAnchor({ [key]: value }));
        } catch (err) {
          message = err.message;
        }

        expect(message).toMatch(new RegExp(`${key}:`));
        expect(message).not.toContain(value);
        expectNoSecretsIn(message);
      });
    });
  });
});
