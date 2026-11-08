// What the backend knows about the deployed MineChain contract (docs/contract-spec.md).
//
// The backend never reads contracts/ at runtime: on Render it may be deployed without that
// folder, and the live contract can never change anyway. Instead this file holds a copy of
// just the parts the anchoring worker uses, and tests/mineChainAbi.test.js checks every line
// against the committed Ignition artifact, the record of what was actually deployed. If the
// two ever disagree, that test fails rather than a transaction on Sepolia.

// Human-readable ABI (an ethers feature): each line is a Solidity signature, which ethers
// turns into the same selectors and topics as the JSON ABI. Parameter names are kept, so
// decoded events and errors can be read by name, for example event.args.dataHash.
//
// Deliberately minimal: grantRole, revokeRole and renounceRole are left out, so the
// recorder's code has no way to even encode a role change.
export const MINECHAIN_ABI = Object.freeze([
  // The three writes, one per custody step (contract spec section 5).
  'function registerConsignment(bytes32 id, bytes32 minerRef, uint64 weightMilligrams, bytes32 dataHash)',
  'function recordHandoff(bytes32 id, bytes32 transporterRef, uint64 weightMilligrams, bytes32 dataHash)',
  'function recordPurchase(bytes32 id, bytes32 buyerRef, uint64 weightMilligrams, bytes32 dataHash)',

  // Reads: the "is this step already on-chain?" check after a crash, and the startup checks.
  'function getConsignment(bytes32 id) view returns ((uint8 stage, uint64 weightMilligrams, uint64 timestamp, bytes32 actorRef, bytes32 dataHash))',
  'function RECORDER_ROLE() view returns (bytes32)',
  'function hasRole(bytes32 role, address account) view returns (bool)',

  // A receipt must contain the matching event before a step counts as confirmed.
  'event ConsignmentRegistered(bytes32 indexed id, bytes32 indexed minerRef, uint64 weightMilligrams, bytes32 dataHash, uint64 timestamp)',
  'event HandoffRecorded(bytes32 indexed id, bytes32 indexed transporterRef, uint64 weightMilligrams, bytes32 dataHash, uint64 timestamp)',
  'event PurchaseRecorded(bytes32 indexed id, bytes32 indexed buyerRef, uint64 weightMilligrams, bytes32 dataHash, uint64 timestamp)',

  // Without these, a revert would arrive as unreadable bytes, and the worker could not tell
  // "stop, the key lost its role" from "retry later" (contract spec section 6).
  'error AccessControlUnauthorizedAccount(address account, bytes32 neededRole)',
  'error InvalidInput(uint8 field)',
  'error InvalidStage(bytes32 id, uint8 current)',
  'error ConsignmentAlreadyExists(bytes32 id)',
]);

// bigint, because ethers v6 reports chain ids as bigint, and 11155111 === 11155111n is false.
export const SEPOLIA_CHAIN_ID = 11155111n;

// The block holding the deployment transaction. No MineChain event can be older, so log
// searches start here instead of at block 0, which public RPCs refuse or rate-limit.
export const DEPLOY_BLOCK = 12047601;

// keccak256 of the deployed runtime bytecode. At startup the worker hashes the code at the
// configured address and compares it with this, which proves the address holds exactly this
// contract, not just any contract. A plain comparison works because MineChain has no
// immutables and no linked libraries, so the deployed bytes equal the artifact's bytes.
export const EXPECTED_CODE_HASH = '0xbabb170f88b64e67a72287b1ffe6a4fb1f29289bcd2c5212f762c2a4b5b55cfa';
