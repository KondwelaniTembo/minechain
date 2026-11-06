import { describe, it, expect } from 'vitest';
import { usernameSchema, registerSchema } from '../src/schemas/auth.js';

// usernameSchema now stands alone so the seed script (and later admin user creation) can
// reuse it. These tests pin its rule; authSchemas.test.js still covers it inside
// registerSchema, unchanged.
describe('usernameSchema', () => {
  it('trims surrounding spaces', () => {
    expect(usernameSchema.parse('  seed_miner ')).toBe('seed_miner');
  });

  it.each(['abc', 'a'.repeat(32), 'Mutale.Banda-2', 'seed_officer'])('accepts %j', (value) => {
    expect(usernameSchema.safeParse(value).success).toBe(true);
  });

  it.each([
    ['2 characters', 'mb', 'must be at least 3 characters'],
    ['33 characters', 'a'.repeat(33), 'must be at most 32 characters'],
    ['a space inside', 'mutale banda', 'may only use letters, digits, and _ . -'],
    // а is Cyrillic а, which looks identical to Latin a.
    ['a look-alike Cyrillic letter', 'аdmin', 'may only use letters, digits, and _ . -'],
    ['only spaces, which trim to nothing', '     ', 'must be at least 3 characters'],
  ])('refuses %s', (_label, value, message) => {
    const result = usernameSchema.safeParse(value);

    expect(result.success).toBe(false);
    expect(result.error.issues.map((i) => i.message)).toContain(message);
  });

  it('is the exact schema registerSchema uses, so the two can never drift apart', () => {
    expect(registerSchema.shape.username).toBe(usernameSchema);
  });
});
