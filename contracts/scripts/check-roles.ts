// Read-only check of the roles on the deployed Sepolia contract.
// Run from contracts/: npx hardhat run scripts/check-roles.ts --network sepolia
import { readFile } from "node:fs/promises";
import { network } from "hardhat";

const SEPOLIA_CHAIN_ID = 11155111n;

const { ethers } = await network.create();

// The deployment record below belongs to Sepolia only, so reading it while
// connected to another network would report on the wrong contract.
const { chainId } = await ethers.provider.getNetwork();
if (chainId !== SEPOLIA_CHAIN_ID) {
  throw new Error(`Expected Sepolia (${SEPOLIA_CHAIN_ID}), connected to ${chainId}`);
}

async function readJson(relativePath: string) {
  return JSON.parse(await readFile(new URL(relativePath, import.meta.url), "utf8"));
}

// Both values come from the files Ignition used, so this check cannot drift
// from what was actually deployed.
const addresses = await readJson(
  "../ignition/deployments/chain-11155111/deployed_addresses.json",
);
const parameters = await readJson("../ignition/parameters/sepolia.json");

const mineChain = await ethers.getContractAt(
  "MineChain",
  addresses["MineChainModule#MineChain"],
);
const recorder: string = parameters.MineChainModule.recorder;
const [deployer] = await ethers.getSigners();

const DEFAULT_ADMIN_ROLE = await mineChain.DEFAULT_ADMIN_ROLE();
const RECORDER_ROLE = await mineChain.RECORDER_ROLE();

const checks = [
  {
    label: "deployer has DEFAULT_ADMIN_ROLE",
    role: DEFAULT_ADMIN_ROLE,
    account: deployer.address,
    expected: true,
  },
  {
    label: "recorder has RECORDER_ROLE",
    role: RECORDER_ROLE,
    account: recorder,
    expected: true,
  },
  {
    label: "deployer does not have RECORDER_ROLE",
    role: RECORDER_ROLE,
    account: deployer.address,
    expected: false,
  },
];

console.log(`MineChain at ${await mineChain.getAddress()}`);

let allPassed = true;
for (const { label, role, account, expected } of checks) {
  const actual = await mineChain.hasRole(role, account);
  const passed = actual === expected;
  allPassed &&= passed;
  console.log(`${passed ? "PASS" : "FAIL"}  ${label} (${account}): ${actual}`);
}

if (!allPassed) {
  process.exitCode = 1;
}
