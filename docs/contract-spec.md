# MineChain contract specification

## 1. Purpose

`MineChain` is the Blockchain Ledger layer of the four-layer architecture. It anchors each
custody step of a mineral consignment on a public blockchain: registration at extraction,
handoffs to transporters, and purchase by a licensed buyer.

| Layer | Role towards the contract |
|---|---|
| Mobile Application | Signs each step with a P-256 key in the Android Keystore. Never talks to the chain |
| API Communication | Carries the signed record to the backend |
| Backend Processing | Verifies the signature, runs the anomaly checks, stores the full record, then writes a compact record and its hash to the contract |
| Blockchain Ledger | Stores the compact record and emits an event for each step |

Only authorised backend wallets can write. Anyone can read, because Sepolia is a public
chain. The ledger is permissioned only through the contract's access control, not through
the network.

## 2. Deployment

| Item | Value |
|---|---|
| Network | Ethereum Sepolia testnet (chain ID 11155111) |
| Address | `0x6419cB5268706E2aA4713AB3bCFc336248Ed158a` |
| Deployed | 2 Nov 2026, with Hardhat Ignition (module `MineChainModule`) |
| Deployment transaction | [`0x0fa2f592…cef5fdb8`](https://sepolia.etherscan.io/tx/0x0fa2f592251b4ca59752d380234b15b23176559d0b9e1b099b5d6c38cef5fdb8), block 12047601 |
| Recorder grant transaction | [`0x1c674680…ca97d895b`](https://sepolia.etherscan.io/tx/0x1c6746809e8d4d429d6ac71cdface9af35efd1a2618e6893fc6768cca97d895b), block 12047606 |
| Compiler | Solidity 0.8.34, `production` profile (optimizer on, 200 runs), EVM target Osaka |
| Dependency | OpenZeppelin Contracts 5.6.1 (`AccessControl`) |
| Admin (`DEFAULT_ADMIN_ROLE`) | `0x186Fa38d9EAf5866946e988E5706053d645Be2CE` (development wallet, the deployer) |
| Recorder (`RECORDER_ROLE`) | `0x25E19030C6cdb1e2608819BceF797a23eb0738fA` (backend recorder wallet) |

Verified source code:

- [Etherscan](https://sepolia.etherscan.io/address/0x6419cB5268706E2aA4713AB3bCFc336248Ed158a#code)
- [Blockscout](https://eth-sepolia.blockscout.com/address/0x6419cB5268706E2aA4713AB3bCFc336248Ed158a?tab=contract)
- [Sourcify](https://repo.sourcify.dev/11155111/0x6419cB5268706E2aA4713AB3bCFc336248Ed158a) (exact match)

Ignition's record of the deployment is in `contracts/ignition/deployments/chain-11155111/`.
The module is `contracts/ignition/modules/MineChain.ts`, and the recorder address is passed
in from `contracts/ignition/parameters/sepolia.json`.

To check the roles on the live contract, run
`npx hardhat run scripts/check-roles.ts --network sepolia` from `contracts/`. The developer
ran it on 2 Nov 2026, and it printed three `PASS` lines:

- Deployer has `DEFAULT_ADMIN_ROLE`: `true`
- Recorder has `RECORDER_ROLE`: `true`
- Deployer does not have `RECORDER_ROLE`: `false`

## 3. Roles and access control

The contract uses OpenZeppelin `AccessControl`.

| Role | Held by | Can do |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` (`0x00…00`) | The deployer | Grant and revoke `RECORDER_ROLE` |
| `RECORDER_ROLE` (`keccak256("RECORDER_ROLE")`) | Backend wallets | Call the three write functions |

**Why the two roles are separate:** the recorder key has to sit on the server, because the
backend signs every write with it, so it is the key most at risk. The admin key does not
need to be online at all. If the server is compromised, the attacker gains a recorder, which
the admin can revoke from a different, offline key. If both roles sat in one wallet, losing
the server would also hand over control of who can write. The deployer is therefore never
granted `RECORDER_ROLE`, and a test confirms the admin cannot write.

Several recorders can hold the role at once, so backend wallets can be added or rotated
without a redeployment.

## 4. Data model

### Stage

| Value | Stage | Meaning |
|---|---|---|
| 0 | `None` | Never registered. A mapping returns zeros for an unknown key, so this is what "not found" looks like |
| 1 | `Registered` | Recorded at extraction |
| 2 | `InTransit` | Held by a transporter |
| 3 | `Purchased` | Bought by a licensed buyer. Final: no function accepts it |

### Consignment (latest step only)

| Field | Type | Meaning |
|---|---|---|
| `stage` | `Stage` | Current position in the custody chain |
| `weightMilligrams` | `uint64` | Weight at the latest step, in whole milligrams |
| `timestamp` | `uint64` | Block time when the latest step was anchored |
| `actorRef` | `bytes32` | Reference to the latest actor (miner, transporter or buyer) |
| `dataHash` | `bytes32` | Hash of the latest signed record held by the backend |

`stage`, `weightMilligrams` and `timestamp` share one storage slot, so each consignment uses
three slots. Consignments are keyed by a `bytes32` id.

### Deliberately not stored on-chain

Sepolia is public and permanent, so the contract holds no personal or location data:

- Names, phone numbers, licence numbers and other identities. Actors appear only as opaque
  `bytes32` references.
- GPS coordinates and extraction zones.
- Mineral type, photos and the full signed record. These are covered by `dataHash`.
- The P-256 signature itself. The backend verifies it.
- The capture time on the device. It is in the signed record.
- Anomaly results and the "held" status. These live in the backend.
- Earlier steps of a consignment. They are in the event logs, not the struct.

Actor references must not be guessable. A plain hash such as `keccak256(phoneNumber)` can be
reversed by hashing every possible number, so references must be random values or keyed
hashes (HMAC) made with a server-side secret.

## 5. Functions

All three write functions check, in this order: role, then inputs, then stage. They then
save the new state and emit an event. A failed check reverts the whole transaction, so no
partial record is ever saved.

| Function | Parameters | Caller | Allowed from | Moves to | Errors |
|---|---|---|---|---|---|
| `registerConsignment` | `id`, `minerRef`, `weightMilligrams`, `dataHash` | `RECORDER_ROLE` | `None` | `Registered` | `AccessControlUnauthorizedAccount`, `InvalidInput`, `ConsignmentAlreadyExists` |
| `recordHandoff` | `id`, `transporterRef`, `weightMilligrams`, `dataHash` | `RECORDER_ROLE` | `Registered`, `InTransit` | `InTransit` | `AccessControlUnauthorizedAccount`, `InvalidInput`, `InvalidStage` |
| `recordPurchase` | `id`, `buyerRef`, `weightMilligrams`, `dataHash` | `RECORDER_ROLE` | `InTransit` | `Purchased` | `AccessControlUnauthorizedAccount`, `InvalidInput`, `InvalidStage` |
| `getConsignment` | `id` | Anyone (view) | Any | — | None. Returns `Stage.None` and zeros for an unknown id |
| `grantRole`, `revokeRole` | `role`, `account` | `DEFAULT_ADMIN_ROLE` | — | — | `AccessControlUnauthorizedAccount` |
| `hasRole` | `role`, `account` | Anyone (view) | — | — | None |

`grantRole`, `revokeRole`, `hasRole`, `renounceRole` and `getRoleAdmin` are inherited from
OpenZeppelin `AccessControl`.

Input rules: `id`, the actor reference and `dataHash` must not be zero, and
`weightMilligrams` must be greater than zero. The contract records weight but does not judge
it. The 10% quantity discrepancy check runs in the backend.

`recordHandoff` is allowed from `InTransit` so that one journey can have several
transporters. `recordPurchase` is rejected from `Registered`, because a purchase with no
transport step would leave a gap in the custody chain.

### Gas used per write

Measured, replacing the earlier estimate of about 95,000 for a registration and 45,000 to
50,000 for the other two:

| Function | Local, Osaka rules | Sepolia, Glamsterdam (live run, 9 Nov 2026) |
|---|---|---|
| `registerConsignment` | 96,645 | 352,951 |
| `recordHandoff` | 45,449 (median; 45,449–45,515) | 59,299 |
| `recordPurchase` | 45,336 | 59,182 |
| Deployment | 1,204,173 (5,201 bytes of bytecode) | — |

The local figures come from `npx hardhat test --gas-stats` in `contracts/` (37 tests
passing). The Sepolia figures are the three transactions of the first live run, recorded in
[live-run-2026-11-09.md](live-run-2026-11-09.md).

**Why a registration costs about six handoffs on Sepolia.** All three writes do the same
work: one role check, one stage read, one three-slot `Consignment` write and one event. The
difference is that a registration creates three new storage slots, while a handoff or
purchase updates existing ones. Sepolia activated the Glamsterdam upgrade on 6 Oct 2026, and
its EIP-8037 (state creation gas) charges every zero-to-non-zero SSTORE 64 state bytes ×
1,530 = 97,920 extra. So 352,951 − 3 × 97,920 = 59,191, the cost of a handoff. EIP-8038
(state access repricing) explains the rest: the handoff and purchase are each about 13,850
dearer than under Osaka. Under Osaka the same pattern holds with the old premium: creating a
slot costs 20,000 where updating costs 2,900, and 96,645 − 3 × 17,100 = 45,345, about a local
handoff.

**Caveats.** EIP-8037 is still in Review, so its cost per state byte may change, and
Glamsterdam is not on mainnet yet: costs depend on the network's gas schedule, not only on
this code. The backend never relies on these numbers to send: it uses each transaction's own
`estimateGas` × 1.2. Only the startup balance check uses a fixed ceiling,
`MAX_GAS_PER_STEP` = 450,000 in `backend/src/chain/preflight.js`.

## 6. Events and errors

### Events

Every event has the same fields: `id` (indexed), the actor reference (indexed),
`weightMilligrams`, `dataHash` and `timestamp`.

| Event | Emitted by | Meaning for the backend |
|---|---|---|
| `ConsignmentRegistered` | `registerConsignment` | Extraction is anchored. Its `dataHash` is the original record's hash |
| `HandoffRecorded` | `recordHandoff` | A transporter took custody. There is one per leg |
| `PurchaseRecorded` | `recordPurchase` | The custody chain is complete |
| `RoleGranted`, `RoleRevoked` | OpenZeppelin | Audit trail of which wallets may write |

The events are the full history of a consignment, because the struct keeps only the latest
step. Filtering logs on the first indexed topic (`id`) returns every step of one
consignment, in order. Filtering on the second (actor reference) returns every step by one
actor.

### Errors

| Error | Cause | What the backend should do |
|---|---|---|
| `AccessControlUnauthorizedAccount(account, neededRole)` | The sending wallet lacks the role | A configuration problem, such as a wrong or revoked key. Stop and alert the administrator. Do not retry |
| `InvalidInput(field)` | A zero id, actor reference, weight or hash. `field` is 0 for Id, 1 for ActorRef, 2 for WeightMilligrams, 3 for DataHash | A backend validation bug. Do not retry. Fix the data |
| `ConsignmentAlreadyExists(id)` | The id is already registered | Read the `ConsignmentRegistered` event. If its `dataHash` matches, an earlier send already succeeded, so treat this as done. If not, raise a duplicate-id anomaly |
| `InvalidStage(id, current)` | The step is not allowed from the current stage | If `current` is `None`, the registration is not anchored yet, so queue this step and retry after it. Otherwise raise a handoff-order anomaly |

`InvalidStage` can happen during normal offline sync. Steps for one consignment must be
sent in order, each after the previous one is confirmed.

## 7. How the backend verifies a record

The contract stores hashes, not records, so checking a record means comparing the database
copy against the hash anchored at the time. The backend does this on every scan of a
consignment ([api.md, the chain check](api.md#the-chain-check)), for each confirmed step.

### 7.1 The key-free reader

Verification reads the chain through `backend/src/chain/chainReader.js`, not through the
anchoring worker's chain client. The reader has no wallet and never reads
`RECORDER_PRIVATE_KEY`, so it works whether or not `ANCHOR_ENABLED` is true. The server
creates it whenever `SEPOLIA_RPC_URL` and `MINECHAIN_CONTRACT_ADDRESS` are set (with
`SEPOLIA_RPC_URL_FALLBACK` as a fallback, used only when the primary cannot be reached).
Creating it makes no network call. It can do two things: fetch a transaction receipt, and
read the latest block number. Each request gives up after 8 seconds.

It shares the provider set-up, fallback rule and event decoding with the chain client
(`backend/src/chain/rpc.js`), and the same secret rules: the RPC URLs stay inside the module,
every provider error becomes a `ChainClientError` with a fixed code, and warnings name an
endpoint only as `primary` or `fallback`, never by host or URL.

**The network check.** Before an endpoint's first answer is trusted, the reader asks that
endpoint, once:

1. `eth_chainId`: it must be 11155111 (Sepolia);
2. `eth_getCode` at the contract address: it must not be empty, and its keccak256 must equal
   `EXPECTED_CODE_HASH`, the hash of the deployed runtime bytecode that the worker's preflight
   also checks (`backend/src/chain/mineChainAbi.js`). The hash is worked out from the reply
   already in hand, so this costs no extra request.

| Refusal | When |
|---|---|
| `WRONG_CHAIN` | The endpoint reports another chain id |
| `NO_CONTRACT_CODE` | There is no code at `MINECHAIN_CONTRACT_ADDRESS` on that endpoint |
| `WRONG_CONTRACT_CODE` | There is code, but not the deployed MineChain |

A refusal fails the request without trying the other endpoint: a wrong network is a
configuration fault, as in the worker's preflight. A failed or refused check is not
remembered, so the next request asks again; once passed, it is not asked again. Until it
passes, every check result is `chain_unavailable`. Without this guard, an RPC on another
network would honestly report "no such receipt" for every honest step.

### 7.2 Comparing a step with the chain

1. **The stored evidence first, with no network** (`backend/src/services/chainCheck.js`):
   `hash_version` must be 1; the anchor hash is recomputed from the stored payload, signer
   public key and signature ([signing spec](signing-spec.md), section 7); the signature is
   verified again; and the signed payload is compared with the stored columns. Any difference
   is a mismatch at once.
2. **The receipt of the stored `chain_tx_hash`**, read with the reader. Its `status` must be 1
   and its `blockNumber` must equal the stored `block_number`.
3. **One event in the receipt must match the step**, by `receiptEventMismatches`, the same
   function the worker uses to confirm a step: the contract address, the event name for the
   step type (`ConsignmentRegistered`, `HandoffRecorded` or `PurchaseRecorded`), the
   consignment `id`, the actor reference, `weightMilligrams` and `dataHash`. The `dataHash` is
   compared with the **recomputed** hash, never the stored `data_hash` column, so the chain is
   compared with the evidence itself.
4. **No receipt** is a mismatch (`TX_NOT_FOUND`) only when the reader's latest block is at
   least the stored `block_number` plus `ANCHOR_CONFIRMATIONS`; before that the RPC may be
   behind, and the result is `chain_unavailable`.
5. **Any reader error**, a network-check refusal included, or no reader configured, gives
   `chain_unavailable`, never a mismatch.

A mismatch raises a `record_tampered` alert on the step, which holds the consignment
([database-schema.md, alerts](database-schema.md#alerts)).

**Why the receipt and not `getLogs`.** The cost is fixed: one `eth_getTransactionReceipt` per
step, plus `eth_blockNumber` only when a receipt is missing. A log search needs a block range
from the deployment block, which grows every day. It is just as safe: the stored hash is only a
pointer, and what is trusted is the event, which only the recorder wallet can emit, matched in
full against the recomputed hash.

### 7.3 Log search, for crash recovery

The anchoring worker can also find a step's event without its transaction hash, after a crash
left a row that never recorded it:

1. Take the consignment's `bytes32` id.
2. Read the logs from the contract address, filtered with
   `topics: [<the three event topics>, id]`, in chunks of 500 blocks. The worker starts near
   the step's received time, and never before the deployment block, 12047601. Decode them with the
   contract ABI.
3. Find the event that matches the step, with the same comparison as in 7.2, step 3.

`getConsignment(id)` gives the consignment's current stage and latest step, which the worker
reads before it ever resends a step.

The hashing scheme belongs to the backend. Once a record has been anchored, that scheme must
not change, or old records will no longer verify. If it ever needs to change, give it a
version number.

## 8. Testing

The tests are in `contracts/test/MineChain.ts`, written with Mocha, Ethers.js and the Hardhat
chai matchers. Each test starts from a clean snapshot through `loadFixture`, so no test
depends on another.

| Group | Tests | Covers |
|---|---|---|
| Deployment | 2 | Deployer has `DEFAULT_ADMIN_ROLE` and not `RECORDER_ROLE` |
| Access control | 8 | Granting and revoking; non-recorders and the admin cannot write; non-admins cannot grant or revoke |
| `registerConsignment` | 3 | Fields stored correctly, event values, duplicate rejected with the original kept |
| `recordHandoff` | 4 | From `Registered` and `InTransit`; unknown and `Purchased` rejected |
| `recordPurchase` | 4 | From `InTransit`; `Registered`, a second purchase and unknown rejected |
| Input validation | 12 | Each of the four zero inputs, for each of the three write functions |
| Check order | 2 | Role checked before inputs, and inputs before stage |
| `getConsignment` | 1 | Unknown id returns `Stage.None` without reverting |
| Full journey | 1 | Register, two handoffs and purchase, rebuilt from logs in order |

Results:

- **37 tests passing.** The developer ran these with `npx hardhat test mocha`.
- **100% line and statement coverage of `MineChain.sol`.** Reported by Claude Code using
  `npx hardhat test mocha --coverage`. The tool does not report branch coverage.
- **Deliberate-failure check, run by Claude Code.** `minerRef` and `dataHash` were swapped
  in `registerConsignment`, both in storage and in the event. Three tests failed: field
  storage, event values and the full journey. The contract was then restored, with its file
  hash matching the original, and all 37 tests passed again. This shows the tests catch a
  mistake the compiler cannot, because both values are `bytes32`.

## 9. Known limitations and future work

- **No export stage.** Custody ends at purchase. Export is in the project objectives but has
  no requirement and did not fit the deadline.
- **No contract-level P-256 signature check.** Phones sign with P-256 keys in the Android
  Keystore, which the EVM's `ecrecover` cannot verify. The backend verifies signatures, and
  the contract trusts its recorders. Contract-level P-256 verification is future work.
- **Only the latest step is stored.** Earlier steps can be rebuilt from events only, so any
  reader needs log access, not just a contract call.
- **Anchoring time can be later than capture time.** The app works offline for up to 72
  hours, so `timestamp` is when the step reached the chain. The real capture time is in the
  signed record covered by `dataHash`.
- **Handoffs are not idempotent.** A repeated `recordHandoff` succeeds again and records a
  second handoff. The backend must confirm a step is not already on-chain before resending
  it.
- **Actor references are pseudonymous, not anonymous.** The same reference on many
  consignments links them publicly, even though it does not name the person.
- **One admin key.** If the admin renounces its role, no one can grant or revoke recorders
  again. There is also no pause or upgrade, so fixing a contract bug means a new deployment
  at a new address.
- **Gas depends on the network's schedule.** Creating a consignment's three storage slots
  dominates the cost of a registration under Glamsterdam's state creation gas (EIP-8037, still
  in Review). Mainnet or a layer 2 may price it differently; see
  [Gas used per write](#gas-used-per-write).
- **Testnet only.** Sepolia is for this prototype. A production system would need a mainnet
  or layer-2 deployment and a security audit.
