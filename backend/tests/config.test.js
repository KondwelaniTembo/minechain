import { describe, it, expect } from 'vitest';
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
});
