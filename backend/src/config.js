import { z } from 'zod';

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

const envSchema = z
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
  })
  .superRefine((env, ctx) => {
    if (env.NODE_ENV !== 'test') return;
    // Tests empty tables between runs, so they must never point at the development database.
    if (!env.TEST_DATABASE_URL) {
      ctx.addIssue({ code: 'custom', path: ['TEST_DATABASE_URL'], message: 'is required when NODE_ENV is test' });
    } else if (env.TEST_DATABASE_URL === env.DATABASE_URL) {
      ctx.addIssue({ code: 'custom', path: ['TEST_DATABASE_URL'], message: 'must differ from DATABASE_URL' });
    }
  });

export function loadConfig(env) {
  const result = envSchema.safeParse(env);

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
  });
}
