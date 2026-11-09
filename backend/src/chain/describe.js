// Turns chain facts into text for logs and the anchor:once script. Only public values go
// in: the recorder address, balances, nonces, check names, fixed problem texts and RPC host
// names (preflight's own messages). Never an RPC URL or a key, which these functions never
// receive.

const WEI_PER_ETH = 10n ** 18n;

// "0.010000 ETH". BigInt arithmetic only, so a balance is never rounded by a float.
export function formatEth(wei, decimals = 6) {
  const whole = wei / WEI_PER_ETH;
  const fraction = (wei % WEI_PER_ETH).toString().padStart(18, '0').slice(0, decimals);
  return `${whole}.${fraction} ETH`;
}

export const etherscanTxUrl = (hash) => `https://sepolia.etherscan.io/tx/${hash}`;

// One line for the server log, for example:
//   Anchoring preflight passed: recorder 0x25E1…, balance 0.010000 ETH, nonce 0; warnings: lowBalance
//   Anchoring preflight did not pass (code failed: there is no contract at …); the worker is not started
export function describePreflight(result) {
  const warnings = result.warnings.length ? `; warnings: ${result.warnings.map((w) => w.name).join(', ')}` : '';
  if (!result.startable) {
    const bad = result.checks.filter((c) => c.status === 'failed' || c.status === 'error');
    const reasons = bad.map((c) => `${c.name} ${c.status}: ${c.problem}`).join('; ');
    return `Anchoring preflight did not pass (${reasons})${warnings}`;
  }
  const { recorderAddress, balanceWei, latestNonce } = result.facts;
  const balance = balanceWei === undefined ? 'balance unknown' : `balance ${formatEth(balanceWei)}`;
  const nonce = latestNonce === undefined ? '' : `, nonce ${latestNonce}`;
  const sending = result.canSend ? '' : ', sending paused';
  return `Anchoring preflight passed: recorder ${recorderAddress}, ${balance}${nonce}${sending}${warnings}`;
}

// Several lines for a person at a terminal: every check and every warning in full.
export function preflightLines(result) {
  const lines = [`Recorder wallet: ${result.facts.recorderAddress}`];
  if (result.facts.balanceWei !== undefined) {
    lines.push(`Balance:         ${formatEth(result.facts.balanceWei)}`);
    lines.push(`Nonce:           ${result.facts.latestNonce} latest, ${result.facts.pendingNonce} pending`);
  }
  lines.push('Checks:');
  for (const check of result.checks) {
    lines.push(`  ${check.name.padEnd(8)} ${check.status}${check.problem ? ` - ${check.problem}` : ''}`);
  }
  if (result.warnings.length) {
    lines.push('Warnings:');
    for (const w of result.warnings) lines.push(`  ${w.name}: ${w.message}`);
  }
  lines.push(result.startable ? (result.canSend ? 'Ready to send.' : 'Startable, but sending is paused.') : 'Not startable.');
  return lines;
}
