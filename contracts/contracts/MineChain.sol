// SPDX-License-Identifier: MIT
// Exact version, not ^0.8.34: deployed code cannot be changed, so the compiler
// that built it should never vary between machines or over time.
pragma solidity 0.8.34;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title MineChain custody ledger
/// @notice Anchors each step of a mineral consignment's custody on Sepolia:
/// registration, handoffs and purchase.
/// @dev Anyone can read this ledger, because Sepolia is public. Only accounts
/// holding RECORDER_ROLE can write to it. For that reason every id, actor ref
/// and hash here is an opaque bytes32, and full records stay in the backend.
contract MineChain is AccessControl {
    /// @notice Role held by the authorised backend wallets that write records.
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    /// @notice Where a consignment is in its custody chain.
    /// @dev None must stay first. A mapping returns zeros for an unknown key,
    /// so stage 0 is what "this id has never been registered" looks like.
    /// Purchased is final, because export is outside the current scope.
    enum Stage {
        None,
        Registered,
        InTransit,
        Purchased
    }

    /// @notice The latest known state of a consignment.
    /// @dev Only the latest step is stored, because earlier steps are already
    /// in the event logs. stage, weightGrams and timestamp share one storage
    /// slot, which is why the two numbers are uint64 rather than uint256.
    /// @param stage Current position in the custody chain.
    /// @param weightGrams Weight at the latest step, in whole grams.
    /// @param timestamp Block time when the latest step was anchored.
    /// @param actorRef Reference to the latest actor.
    /// @param dataHash Hash of the latest signed record held by the backend.
    struct Consignment {
        Stage stage;
        uint64 weightGrams;
        uint64 timestamp;
        bytes32 actorRef;
        bytes32 dataHash;
    }

    // private only stops Solidity generating a getter. The data is still
    // public on-chain, and getConsignment is the documented way to read it.
    mapping(bytes32 id => Consignment) private consignments;

    /// @notice The write inputs that can fail validation.
    /// @dev Used by InvalidInput so a caller can tell which value was wrong.
    enum InputField {
        Id,
        ActorRef,
        WeightGrams,
        DataHash
    }

    /// @notice A required input was zero.
    /// @param field The input that was rejected.
    error InvalidInput(InputField field);

    /// @notice The id has already been registered.
    /// @param id The consignment id that was rejected.
    error ConsignmentAlreadyExists(bytes32 id);

    /// @notice The requested step is not allowed from the current stage.
    /// @dev An unknown id reports Stage.None, so no separate error is needed.
    /// @param id The consignment id that was rejected.
    /// @param current The stage the consignment is in now.
    error InvalidStage(bytes32 id, Stage current);

    /// @notice A consignment was registered at extraction.
    /// @param id The consignment id.
    /// @param minerRef Reference to the miner.
    /// @param weightGrams Weight in whole grams. Recorded here, judged by the backend.
    /// @param dataHash Hash of the signed record held by the backend.
    /// @param timestamp Block time of anchoring, which may be later than the
    /// real capture time because the app works offline.
    event ConsignmentRegistered(
        bytes32 indexed id,
        bytes32 indexed minerRef,
        uint64 weightGrams,
        bytes32 dataHash,
        uint64 timestamp
    );

    /// @notice A consignment was handed to a transporter.
    /// @param id The consignment id.
    /// @param transporterRef Reference to the transporter.
    /// @param weightGrams Weight in whole grams. Recorded here, judged by the backend.
    /// @param dataHash Hash of the signed record held by the backend.
    /// @param timestamp Block time of anchoring, which may be later than the
    /// real capture time because the app works offline.
    event HandoffRecorded(
        bytes32 indexed id,
        bytes32 indexed transporterRef,
        uint64 weightGrams,
        bytes32 dataHash,
        uint64 timestamp
    );

    /// @notice A consignment was purchased by a licensed buyer.
    /// @param id The consignment id.
    /// @param buyerRef Reference to the buyer.
    /// @param weightGrams Weight in whole grams. Recorded here, judged by the backend.
    /// @param dataHash Hash of the signed record held by the backend.
    /// @param timestamp Block time of anchoring, which may be later than the
    /// real capture time because the app works offline.
    event PurchaseRecorded(
        bytes32 indexed id,
        bytes32 indexed buyerRef,
        uint64 weightGrams,
        bytes32 dataHash,
        uint64 timestamp
    );

    /// @notice Makes the deployer the admin who grants and revokes recorders.
    /// @dev The deployer is deliberately not made a recorder, so the admin key
    /// never has to sit on the server alongside the recorder wallets.
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Registers a new consignment at extraction.
    /// @dev The backend runs its own duplicate check first. This one is the
    /// last line of defence, and it cannot be bypassed by a backend bug.
    /// @param id The new consignment id.
    /// @param minerRef Reference to the miner.
    /// @param weightGrams Weight in whole grams.
    /// @param dataHash Hash of the signed record held by the backend.
    function registerConsignment(
        bytes32 id,
        bytes32 minerRef,
        uint64 weightGrams,
        bytes32 dataHash
    ) external onlyRole(RECORDER_ROLE) {
        _validateInput(id, minerRef, weightGrams, dataHash);

        if (consignments[id].stage != Stage.None) {
            revert ConsignmentAlreadyExists(id);
        }

        // The cast cannot overflow: uint64 seconds outlast any real block time.
        uint64 timestamp = uint64(block.timestamp);
        consignments[id] = Consignment(
            Stage.Registered,
            weightGrams,
            timestamp,
            minerRef,
            dataHash
        );

        emit ConsignmentRegistered(id, minerRef, weightGrams, dataHash, timestamp);
    }

    /// @notice Records a consignment passing to a transporter.
    /// @dev Allowed from InTransit as well as Registered, so that one journey
    /// can have several transporters.
    /// @param id The consignment id.
    /// @param transporterRef Reference to the transporter.
    /// @param weightGrams Weight in whole grams.
    /// @param dataHash Hash of the signed record held by the backend.
    function recordHandoff(
        bytes32 id,
        bytes32 transporterRef,
        uint64 weightGrams,
        bytes32 dataHash
    ) external onlyRole(RECORDER_ROLE) {
        _validateInput(id, transporterRef, weightGrams, dataHash);

        Stage current = consignments[id].stage;
        if (current != Stage.Registered && current != Stage.InTransit) {
            revert InvalidStage(id, current);
        }

        // The cast cannot overflow: uint64 seconds outlast any real block time.
        uint64 timestamp = uint64(block.timestamp);
        consignments[id] = Consignment(
            Stage.InTransit,
            weightGrams,
            timestamp,
            transporterRef,
            dataHash
        );

        emit HandoffRecorded(id, transporterRef, weightGrams, dataHash, timestamp);
    }

    /// @notice Records the purchase of a consignment by a licensed buyer.
    /// @dev Only allowed from InTransit: a purchase straight from Registered
    /// would leave a gap in the custody chain. Purchased is final, so no
    /// function accepts a consignment after this step.
    /// @param id The consignment id.
    /// @param buyerRef Reference to the buyer.
    /// @param weightGrams Weight in whole grams.
    /// @param dataHash Hash of the signed record held by the backend.
    function recordPurchase(
        bytes32 id,
        bytes32 buyerRef,
        uint64 weightGrams,
        bytes32 dataHash
    ) external onlyRole(RECORDER_ROLE) {
        _validateInput(id, buyerRef, weightGrams, dataHash);

        Stage current = consignments[id].stage;
        if (current != Stage.InTransit) {
            revert InvalidStage(id, current);
        }

        // The cast cannot overflow: uint64 seconds outlast any real block time.
        uint64 timestamp = uint64(block.timestamp);
        consignments[id] = Consignment(
            Stage.Purchased,
            weightGrams,
            timestamp,
            buyerRef,
            dataHash
        );

        emit PurchaseRecorded(id, buyerRef, weightGrams, dataHash, timestamp);
    }

    /// @notice Returns the latest known state of a consignment.
    /// @dev Does not revert for an unknown id. It returns Stage.None instead,
    /// so "not found" is an ordinary answer when verifying a scanned QR code.
    /// @param id The consignment id to look up.
    /// @return The consignment's current state.
    function getConsignment(bytes32 id) external view returns (Consignment memory) {
        return consignments[id];
    }

    /// @notice Rejects zero values in the inputs shared by every write.
    /// @dev The backend validates too, but records here can never be deleted,
    /// so a blank value from a backend bug must not reach the ledger. This
    /// only catches missing values. Whether a value is correct stays a
    /// backend decision, including weight discrepancies.
    /// @param id The consignment id.
    /// @param actorRef Reference to the miner, transporter or buyer.
    /// @param weightGrams Weight in whole grams.
    /// @param dataHash Hash of the signed record held by the backend.
    function _validateInput(
        bytes32 id,
        bytes32 actorRef,
        uint64 weightGrams,
        bytes32 dataHash
    ) internal pure {
        if (id == bytes32(0)) revert InvalidInput(InputField.Id);
        if (actorRef == bytes32(0)) revert InvalidInput(InputField.ActorRef);
        if (weightGrams == 0) revert InvalidInput(InputField.WeightGrams);
        if (dataHash == bytes32(0)) revert InvalidInput(InputField.DataHash);
    }
}
