import { describe, it, expect, vi } from 'vitest';
import { assertDemoAllowed, runDemoJourney, DemoJourneyError } from '../src/cli/demoJourney.js';

// The refusal comes before anything is read or written, so these need no database: every
// dependency here fails the test if it is touched at all.
const untouchable = () => {
  throw new Error('must not be used');
};
const db = { query: untouchable, transaction: untouchable };
const services = { users: { registerPublicKey: untouchable }, sync: { syncSteps: untouchable } };

describe('demo:journey refuses to run outside development', () => {
  it.each(['production', 'test'])('refuses NODE_ENV=%s before touching the database', async (nodeEnv) => {
    const passwords = { hash: vi.fn() };

    await expect(runDemoJourney({ db, services, nodeEnv, passwords, log: untouchable })).rejects.toThrow(DemoJourneyError);
    await expect(runDemoJourney({ db, services, nodeEnv, passwords, log: untouchable })).rejects.toThrow(
      `Refusing to run demo:journey while NODE_ENV is ${nodeEnv}`,
    );
    expect(passwords.hash).not.toHaveBeenCalled();
  });

  it('allows development', () => {
    expect(() => assertDemoAllowed('development')).not.toThrow();
  });
});
