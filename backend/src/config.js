import { z } from 'zod';
// Used for one offline check only: the address checksum. Nothing here touches the network;
// all chain calls live in the chain client.
import { getAddress } from 'ethers';
import { SEPOLIA_CHAIN_ID } from './chain/mineChainAbi.js';

// NFR-01: a stolen token must stop working within an hour, so longer lifetimes are refused
// at startup rather than trusted to whoever edits .env.
const MAX_TOKEN_LIFETIME_SECONDS = 60 * 60;
const SECONDS_PER_UNIT = { s: 1, m: 60, h: 60 * 60 };

const tokenLifetime = z
  .string()
  .regex(/^\d+[smh]$/, 'must be a whole number followed by s, m or h, for example 60m')
  // Converted to seconds here so the rest of the code never has to parse "60m" again.
  .transform((value) => Number(value.slice(0, -1)) * SECONDS_PER_UNIT[value.slice(-1)])
  .refine(
    (seconds) => seconds > 0 && seconds <= MAX_TOKEN_LIFETIME_SECONDS,
    'must be more than 0 and at most 60m (NFR-01)',
  );

const postgresUrl = z
  .string()
  .regex(/^postgres(ql)?:\/\/\S+$/, 'must be a postgresql:// connection string');

// ---------------------------------------------------------------------------------------
// Anchoring settings (docs/contract-spec.md). All optional while ANCHOR_ENABLED is false.
// ---------------------------------------------------------------------------------------

const PLACEHOLDER_MARKER = 'replace-with';

// The settings that can be left out while anchoring is off. The three secrets are also the
// ones .env.example fills with placeholders.
const ANCHOR_KEYS = [
  'ANCHOR_ENABLED',
  'SEPOLIA_RPC_URL',
  'SEPOLIA_RPC_URL_FALLBACK',
  'MINECHAIN_CONTRACT_ADDRESS',
  'RECORDER_PRIVATE_KEY',
  'CHAIN_ID',
  'ANCHOR_INTERVAL_SECONDS',
  'ANCHOR_CONFIRMATIONS',
  'ANCHOR_MAX_ATTEMPTS',
  'ANCHOR_LOW_BALANCE_ETH',
  'ANCHOR_MAX_FEE_GWEI',
];
const ANCHOR_SECRET_KEYS = ['SEPOLIA_RPC_URL', 'SEPOLIA_RPC_URL_FALLBACK', 'RECORDER_PRIVATE_KEY'];
const REQUIRED_WHEN_ENABLED = ['SEPOLIA_RPC_URL', 'MINECHAIN_CONTRACT_ADDRESS', 'RECORDER_PRIVATE_KEY'];

// Private keys are numbers from 1 to n - 1, where n is the order of the secp256k1 curve.
// A 64-hex value at or above n has the right shape but is not a key any wallet can use.
const SECP256K1_ORDER = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;

// A text setting checked by a function that returns a problem message or null. The message
// is about the rule, never the value, because these values include secrets.
function textSetting(findProblem) {
  return z.string().superRefine((value, ctx) => {
    const problem = value.includes(PLACEHOLDER_MARKER)
      ? 'still holds the .env.example placeholder'
      : findProblem(value);
    if (problem) ctx.addIssue({ code: 'custom', message: problem });
  });
}

// The normalised URL, or null when value is missing or does not parse. Never throws: Node's
// URL TypeError carries the raw text in err.input, and these URLs hold API keys.
function safeHref(value) {
  if (typeof value !== 'string') return null;
  try {
    return new URL(value).href;
  } catch {
    return null;
  }
}

const httpsUrl = textSetting((value) => {
  let url;
  try {
    url = new URL(value);
  } catch {
    return 'must be a full URL, for example https://…';
  }
  // The URL usually carries the provider's API key, which plain http would send in clear.
  return url.protocol === 'https:' ? null : 'must start with https://';
});

const contractAddress = textSetting((value) => {
  if (!/^0x[0-9a-fA-F]{40}$/.test(value)) return 'must be 0x followed by 40 hex characters';
  // The mixed case of an Ethereum address is a checksum (EIP-55): a mistyped character
  // almost always breaks it. All-lower-case carries no checksum, so it is refused too.
  let checksummed;
  try {
    checksummed = getAddress(value);
  } catch {
    // ethers' error repeats the value, so it is replaced by our own message.
    return 'has a wrong checksum: copy it exactly as docs/contract-spec.md or Etherscan shows it';
  }
  if (value !== checksummed) return 'must be in checksummed mixed case, exactly as Etherscan shows it';
  return BigInt(value) === 0n ? 'must not be the zero address' : null;
});

const privateKey = textSetting((value) => {
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) {
    return 'must be 0x followed by 64 hex characters (add 0x if your wallet exported it without)';
  }
  const number = BigInt(value);
  if (number === 0n) return 'must not be zero';
  return number < SECP256K1_ORDER ? null : 'is not a valid secp256k1 private key';
});

// Turns decimal text such as "0.002" into whole units (wei) using only string and BigInt
// steps. Number("0.1") is a binary float, slightly off, and the error would end up in a
// balance comparison. Here "0.002" ETH is exactly 2000000000000000n wei.
function decimalToUnits(text, decimals) {
  const [whole, fraction = ''] = text.split('.');
  return BigInt(whole + fraction.padEnd(decimals, '0'));
}

function decimalSetting(decimals, { allowZero }) {
  const pattern = new RegExp(`^\\d{1,9}(\\.\\d{1,${decimals}})?$`);
  return textSetting((value) => {
    if (!pattern.test(value)) {
      return `must be a decimal number such as 0.5, with at most ${decimals} decimal places`;
    }
    return !allowZero && decimalToUnits(value, decimals) === 0n ? 'must be more than 0' : null;
  }).transform((value) => decimalToUnits(value, decimals));
}

const ETH_DECIMALS = 18;
const GWEI_DECIMALS = 9;

const wholeNumber = (min, max, fallback) => z.coerce.number().int().min(min).max(max).default(fallback);

// .env files write an unset value as "NAME=". For the anchoring settings an empty value
// means "not set", and so does an untouched placeholder while anchoring is off, so a
// copied .env.example still starts the API. With anchoring on, a placeholder is kept and
// refused by its rule, because it would mean the setup was not finished.
// requireChain: a script that talks to the chain needs the settings even with anchoring
// off, so its placeholders are kept and refused, as with anchoring on.
function withoutUnsetAnchorValues(env, { requireChain = false } = {}) {
  const cleaned = { ...env };
  const enabled = env.ANCHOR_ENABLED === 'true' || requireChain;
  for (const key of ANCHOR_KEYS) {
    const value = cleaned[key];
    if (value === '') delete cleaned[key];
    if (!enabled && ANCHOR_SECRET_KEYS.includes(key) && value?.includes(PLACEHOLDER_MARKER)) {
      delete cleaned[key];
    }
  }
  return cleaned;
}

// Built per call because one rule depends on how the caller loads config (requireChain).
const envSchemaFor = ({ requireChain }) => z
  .object({
    NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
    // Environment variables are always strings, so coerce turns "3000" into 3000.
    PORT: z.coerce.number().int().min(1).max(65535).default(3000),
    DATABASE_URL: postgresUrl,
    TEST_DATABASE_URL: postgresUrl.optional(),
    JWT_SECRET: z
      .string()
      // HS256 needs a 256-bit key. 43 base64url characters carry 256 bits of randomness
      // (6 bits each), so anything shorter cannot be strong enough.
      .min(43, 'must be at least 43 characters (256 bits for HS256)')
      // Catches a .env copied from .env.example without the placeholder being replaced.
      .refine((value) => !value.startsWith('replace-with'), 'still holds the .env.example placeholder'),
    JWT_EXPIRES_IN: tokenLifetime,
    // How many proxies sit in front of the app. Render adds one, so it will be 1 there.
    // With 0, req.ip is the direct caller; behind a proxy that would be the proxy itself,
    // and every client would share one rate limit.
    TRUST_PROXY: z.coerce.number().int().min(0).max(5).default(0),

    // An enum, not z.coerce.boolean(): coercion makes any non-empty string true, so
    // ANCHOR_ENABLED=false would switch anchoring ON.
    ANCHOR_ENABLED: z
      .enum(['true', 'false'], { error: 'must be true or false' })
      .default('false')
      .transform((value) => value === 'true'),
    SEPOLIA_RPC_URL: httpsUrl.optional(),
    SEPOLIA_RPC_URL_FALLBACK: httpsUrl.optional(),
    MINECHAIN_CONTRACT_ADDRESS: contractAddress.optional(),
    RECORDER_PRIVATE_KEY: privateKey.optional(),
    // Only Sepolia is accepted: the deploy block and code hash in src/chain/mineChainAbi.js
    // belong to the Sepolia deployment. Stating it here still matters, because the startup
    // check compares it with what the RPC provider reports, and CHAIN_ID=1 (mainnet, real
    // money) is refused before anything connects.
    CHAIN_ID: z
      .string()
      .regex(/^\d+$/, 'must be a whole number')
      // The refine can run even when the regex failed, and BigInt('abc') throws, so it
      // checks the shape again before converting.
      .refine(
        (value) => /^\d+$/.test(value) && BigInt(value) === SEPOLIA_CHAIN_ID,
        `must be ${SEPOLIA_CHAIN_ID} (Sepolia)`,
      )
      .default(String(SEPOLIA_CHAIN_ID))
      .transform((value) => BigInt(value)),
    ANCHOR_INTERVAL_SECONDS: wholeNumber(5, 3600, 30),
    // Sepolia makes a block about every 12 seconds; 2 confirmations is about half a minute.
    ANCHOR_CONFIRMATIONS: wholeNumber(1, 12, 2),
    ANCHOR_MAX_ATTEMPTS: wholeNumber(1, 20, 5),
    // In Zod 4 a default is returned as it is, without going through the rules or the
    // transform, so these defaults are given already converted to wei.
    // 0 turns the warning off; sending still pauses when one transaction cannot be paid for.
    ANCHOR_LOW_BALANCE_ETH: decimalSetting(ETH_DECIMALS, { allowZero: true }).default(
      decimalToUnits('0.002', ETH_DECIMALS),
    ),
    // Above this fee per gas the worker waits instead of spending, so a gas spike on Sepolia
    // cannot drain the recorder wallet in a few transactions.
    ANCHOR_MAX_FEE_GWEI: decimalSetting(GWEI_DECIMALS, { allowZero: false }).default(
      decimalToUnits('50', GWEI_DECIMALS),
    ),
  })
  .superRefine((env, ctx) => {
    if (env.NODE_ENV === 'test') {
      // Tests empty tables between runs, so they must never point at the development database.
      if (!env.TEST_DATABASE_URL) {
        ctx.addIssue({ code: 'custom', path: ['TEST_DATABASE_URL'], message: 'is required when NODE_ENV is test' });
      } else if (env.TEST_DATABASE_URL === env.DATABASE_URL) {
        ctx.addIssue({ code: 'custom', path: ['TEST_DATABASE_URL'], message: 'must differ from DATABASE_URL' });
      }
    }

    if (env.ANCHOR_ENABLED || requireChain) {
      const message = env.ANCHOR_ENABLED
        ? 'is required when ANCHOR_ENABLED is true'
        : 'is required by this command, which talks to the chain even with ANCHOR_ENABLED false';
      for (const key of REQUIRED_WHEN_ENABLED) {
        if (env[key] === undefined) {
          ctx.addIssue({ code: 'custom', path: [key], message });
        }
      }
    }

    // Compared as parsed URLs, so "https://a.example" and "https://a.example/" count as the
    // same provider. A fallback that is the primary again gives no protection at all.
    // Zod still runs this after a field rule has failed, so either value may be unparseable
    // here; that case is already reported by the field's own rule.
    const primaryHref = safeHref(env.SEPOLIA_RPC_URL);
    const fallbackHref = safeHref(env.SEPOLIA_RPC_URL_FALLBACK);
    if (primaryHref !== null && primaryHref === fallbackHref) {
      ctx.addIssue({ code: 'custom', path: ['SEPOLIA_RPC_URL_FALLBACK'], message: 'must differ from SEPOLIA_RPC_URL' });
    }
  });

// The anchoring part of the config. The three secrets are non-enumerable getters over
// values held in this closure, so console.log, util.inspect and JSON.stringify, which all
// list only enumerable properties, never show them, while code that asks by name still gets
// them. Note that a spread copy ({ ...config.anchor }) leaves them out too.
function createAnchorConfig(parsed) {
  const secrets = {
    rpcUrl: parsed.SEPOLIA_RPC_URL ?? null,
    fallbackRpcUrl: parsed.SEPOLIA_RPC_URL_FALLBACK ?? null,
    recorderPrivateKey: parsed.RECORDER_PRIVATE_KEY ?? null,
  };

  const anchor = {
    enabled: parsed.ANCHOR_ENABLED,
    chainId: parsed.CHAIN_ID,
    // Public on Etherscan, so an ordinary property.
    contractAddress: parsed.MINECHAIN_CONTRACT_ADDRESS ?? null,
    intervalSeconds: parsed.ANCHOR_INTERVAL_SECONDS,
    confirmations: parsed.ANCHOR_CONFIRMATIONS,
    maxAttempts: parsed.ANCHOR_MAX_ATTEMPTS,
    lowBalanceWei: parsed.ANCHOR_LOW_BALANCE_ETH,
    maxFeePerGasWei: parsed.ANCHOR_MAX_FEE_GWEI,
  };
  for (const [name, value] of Object.entries(secrets)) {
    Object.defineProperty(anchor, name, { get: () => value, enumerable: false });
  }
  return Object.freeze(anchor);
}

// options.requireChain: for scripts such as anchor:once, which need the chain settings
// (RPC URL, contract address, recorder key) whether or not the server's worker is enabled.
// config.anchor.enabled still reports ANCHOR_ENABLED itself.
export function loadConfig(env, { requireChain = false } = {}) {
  const result = envSchemaFor({ requireChain }).safeParse(withoutUnsetAnchorValues(env, { requireChain }));

  if (!result.success) {
    // Only variable names and rule messages are reported, never the values, because the
    // values include secrets and startup errors end up in Render's logs.
    const problems = result.error.issues.map((issue) => `  - ${issue.path.join('.')}: ${issue.message}`);
    throw new Error(`Invalid environment configuration:\n${problems.join('\n')}`);
  }

  const parsed = result.data;
  // Frozen so no module can change a setting while the server is running.
  return Object.freeze({
    nodeEnv: parsed.NODE_ENV,
    port: parsed.PORT,
    // The database choice is made once, here, so no other module has to check NODE_ENV.
    databaseUrl: parsed.NODE_ENV === 'test' ? parsed.TEST_DATABASE_URL : parsed.DATABASE_URL,
    jwtSecret: parsed.JWT_SECRET,
    jwtExpiresInSeconds: parsed.JWT_EXPIRES_IN,
    trustProxyHops: parsed.TRUST_PROXY,
    anchor: createAnchorConfig(parsed),
  });
}
