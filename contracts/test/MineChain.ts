import { expect } from "chai";
import { network } from "hardhat";

const { ethers, networkHelpers } = await network.create();

// Every value is different so that a swapped argument can never pass by accident.
const ID = ethers.id("consignment-1");
const UNKNOWN_ID = ethers.id("consignment-never-registered");
const MINER_REF = ethers.id("miner-ref");
const TRANSPORTER_REF = ethers.id("transporter-ref");
const TRANSPORTER_REF_2 = ethers.id("transporter-ref-2");
const BUYER_REF = ethers.id("buyer-ref");
const HASH_1 = ethers.id("record-1");
const HASH_2 = ethers.id("record-2");
const HASH_3 = ethers.id("record-3");
const HASH_4 = ethers.id("record-4");
const WEIGHT_1 = 1000n;
const WEIGHT_2 = 990n;
const WEIGHT_3 = 985n;
const WEIGHT_4 = 980n;

// Ethers returns enums as bigints. These must match the order in the contract,
// so reordering the Solidity enum fails the tests.
const Stage = { None: 0n, Registered: 1n, InTransit: 2n, Purchased: 3n };
const InputField = { Id: 0n, ActorRef: 1n, WeightMilligrams: 2n, DataHash: 3n };

type ConsignmentValues = {
  stage: bigint;
  weightMilligrams: bigint;
  timestamp: bigint;
  actorRef: string;
  dataHash: string;
};

// Fixes the next block's time so a test knows the exact value to expect,
// instead of accepting any timestamp at all.
async function nextTimestamp() {
  const timestamp = (await networkHelpers.time.latest()) + 60;
  await networkHelpers.time.setNextBlockTimestamp(timestamp);
  return BigInt(timestamp);
}

// Checks all five fields together, so no test can skip one by accident.
function expectConsignment(
  actual: ConsignmentValues,
  expected: ConsignmentValues,
) {
  expect(actual.stage).to.equal(expected.stage);
  expect(actual.weightMilligrams).to.equal(expected.weightMilligrams);
  expect(actual.timestamp).to.equal(expected.timestamp);
  expect(actual.actorRef).to.equal(expected.actorRef);
  expect(actual.dataHash).to.equal(expected.dataHash);
}

async function deployFixture() {
  const [admin, recorder, stranger] = await ethers.getSigners();
  const mineChain = await ethers.deployContract("MineChain");
  const RECORDER_ROLE = await mineChain.RECORDER_ROLE();
  const DEFAULT_ADMIN_ROLE = await mineChain.DEFAULT_ADMIN_ROLE();

  await mineChain.grantRole(RECORDER_ROLE, recorder.address);

  return {
    mineChain,
    asRecorder: mineChain.connect(recorder),
    admin,
    recorder,
    stranger,
    RECORDER_ROLE,
    DEFAULT_ADMIN_ROLE,
  };
}

// The stage fixtures build on each other, so each test can start at the exact
// stage it needs without repeating the steps that lead there.
async function registeredFixture() {
  const fixture = await deployFixture();
  await fixture.asRecorder.registerConsignment(ID, MINER_REF, WEIGHT_1, HASH_1);
  return fixture;
}

async function inTransitFixture() {
  const fixture = await registeredFixture();
  await fixture.asRecorder.recordHandoff(
    ID,
    TRANSPORTER_REF,
    WEIGHT_2,
    HASH_2,
  );
  return fixture;
}

async function purchasedFixture() {
  const fixture = await inTransitFixture();
  await fixture.asRecorder.recordPurchase(ID, BUYER_REF, WEIGHT_3, HASH_3);
  return fixture;
}

describe("MineChain", function () {
  describe("Deployment", function () {
    it("gives the deployer DEFAULT_ADMIN_ROLE", async function () {
      const { mineChain, admin, DEFAULT_ADMIN_ROLE } =
        await networkHelpers.loadFixture(deployFixture);

      expect(await mineChain.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.equal(
        true,
      );
    });

    it("does not give the deployer RECORDER_ROLE", async function () {
      const { mineChain, admin, RECORDER_ROLE } =
        await networkHelpers.loadFixture(deployFixture);

      expect(await mineChain.hasRole(RECORDER_ROLE, admin.address)).to.equal(
        false,
      );
    });
  });

  describe("Access control", function () {
    it("lets the admin grant RECORDER_ROLE, and the new recorder can write", async function () {
      const { mineChain, stranger, RECORDER_ROLE } =
        await networkHelpers.loadFixture(deployFixture);

      await mineChain.grantRole(RECORDER_ROLE, stranger.address);

      await expect(
        mineChain
          .connect(stranger)
          .registerConsignment(ID, MINER_REF, WEIGHT_1, HASH_1),
      ).to.emit(mineChain, "ConsignmentRegistered");
    });

    it("lets the admin revoke RECORDER_ROLE, and the next write reverts", async function () {
      const { mineChain, asRecorder, recorder, RECORDER_ROLE } =
        await networkHelpers.loadFixture(deployFixture);

      await mineChain.revokeRole(RECORDER_ROLE, recorder.address);

      await expect(
        asRecorder.registerConsignment(ID, MINER_REF, WEIGHT_1, HASH_1),
      )
        .to.be.revertedWithCustomError(
          mineChain,
          "AccessControlUnauthorizedAccount",
        )
        .withArgs(recorder.address, RECORDER_ROLE);
    });

    it("rejects registerConsignment from a non-recorder", async function () {
      const { mineChain, stranger, RECORDER_ROLE } =
        await networkHelpers.loadFixture(deployFixture);

      await expect(
        mineChain
          .connect(stranger)
          .registerConsignment(ID, MINER_REF, WEIGHT_1, HASH_1),
      )
        .to.be.revertedWithCustomError(
          mineChain,
          "AccessControlUnauthorizedAccount",
        )
        .withArgs(stranger.address, RECORDER_ROLE);
    });

    // Starts at Registered so that the missing role is the only thing wrong.
    it("rejects recordHandoff from a non-recorder", async function () {
      const { mineChain, stranger, RECORDER_ROLE } =
        await networkHelpers.loadFixture(registeredFixture);

      await expect(
        mineChain
          .connect(stranger)
          .recordHandoff(ID, TRANSPORTER_REF, WEIGHT_2, HASH_2),
      )
        .to.be.revertedWithCustomError(
          mineChain,
          "AccessControlUnauthorizedAccount",
        )
        .withArgs(stranger.address, RECORDER_ROLE);
    });

    // Starts at InTransit so that the missing role is the only thing wrong.
    it("rejects recordPurchase from a non-recorder", async function () {
      const { mineChain, stranger, RECORDER_ROLE } =
        await networkHelpers.loadFixture(inTransitFixture);

      await expect(
        mineChain
          .connect(stranger)
          .recordPurchase(ID, BUYER_REF, WEIGHT_3, HASH_3),
      )
        .to.be.revertedWithCustomError(
          mineChain,
          "AccessControlUnauthorizedAccount",
        )
        .withArgs(stranger.address, RECORDER_ROLE);
    });

    // The admin key must not be able to write records: the two roles are
    // separate so that the admin key can stay off the server.
    it("rejects a write from the admin", async function () {
      const { mineChain, admin, RECORDER_ROLE } =
        await networkHelpers.loadFixture(deployFixture);

      await expect(
        mineChain.registerConsignment(ID, MINER_REF, WEIGHT_1, HASH_1),
      )
        .to.be.revertedWithCustomError(
          mineChain,
          "AccessControlUnauthorizedAccount",
        )
        .withArgs(admin.address, RECORDER_ROLE);
    });

    // The caller is a recorder on purpose, which also proves that a recorder
    // wallet cannot hand its role to another account.
    it("rejects grantRole from a non-admin", async function () {
      const { mineChain, asRecorder, recorder, stranger, RECORDER_ROLE, DEFAULT_ADMIN_ROLE } =
        await networkHelpers.loadFixture(deployFixture);

      await expect(asRecorder.grantRole(RECORDER_ROLE, stranger.address))
        .to.be.revertedWithCustomError(
          mineChain,
          "AccessControlUnauthorizedAccount",
        )
        .withArgs(recorder.address, DEFAULT_ADMIN_ROLE);
    });

    it("rejects revokeRole from a non-admin", async function () {
      const { mineChain, recorder, stranger, RECORDER_ROLE, DEFAULT_ADMIN_ROLE } =
        await networkHelpers.loadFixture(deployFixture);

      await expect(
        mineChain.connect(stranger).revokeRole(RECORDER_ROLE, recorder.address),
      )
        .to.be.revertedWithCustomError(
          mineChain,
          "AccessControlUnauthorizedAccount",
        )
        .withArgs(stranger.address, DEFAULT_ADMIN_ROLE);
    });
  });

  describe("registerConsignment", function () {
    it("stores every field in the right place", async function () {
      const { mineChain, asRecorder } =
        await networkHelpers.loadFixture(deployFixture);
      const timestamp = await nextTimestamp();

      await asRecorder.registerConsignment(ID, MINER_REF, WEIGHT_1, HASH_1);

      expectConsignment(await mineChain.getConsignment(ID), {
        stage: Stage.Registered,
        weightMilligrams: WEIGHT_1,
        timestamp,
        actorRef: MINER_REF,
        dataHash: HASH_1,
      });
    });

    it("emits ConsignmentRegistered with the right values", async function () {
      const { mineChain, asRecorder } =
        await networkHelpers.loadFixture(deployFixture);
      const timestamp = await nextTimestamp();

      await expect(
        asRecorder.registerConsignment(ID, MINER_REF, WEIGHT_1, HASH_1),
      )
        .to.emit(mineChain, "ConsignmentRegistered")
        .withArgs(ID, MINER_REF, WEIGHT_1, HASH_1, timestamp);
    });

    // The duplicate uses different values, so an overwrite would be visible.
    it("rejects a duplicate id and keeps the original record", async function () {
      const { mineChain, asRecorder } =
        await networkHelpers.loadFixture(registeredFixture);
      const original = await mineChain.getConsignment(ID);

      await expect(
        asRecorder.registerConsignment(ID, BUYER_REF, WEIGHT_4, HASH_4),
      )
        .to.be.revertedWithCustomError(mineChain, "ConsignmentAlreadyExists")
        .withArgs(ID);

      expectConsignment(await mineChain.getConsignment(ID), original);
    });
  });

  describe("recordHandoff", function () {
    it("moves a Registered consignment to InTransit", async function () {
      const { mineChain, asRecorder } =
        await networkHelpers.loadFixture(registeredFixture);
      const timestamp = await nextTimestamp();

      await expect(
        asRecorder.recordHandoff(ID, TRANSPORTER_REF, WEIGHT_2, HASH_2),
      )
        .to.emit(mineChain, "HandoffRecorded")
        .withArgs(ID, TRANSPORTER_REF, WEIGHT_2, HASH_2, timestamp);

      expectConsignment(await mineChain.getConsignment(ID), {
        stage: Stage.InTransit,
        weightMilligrams: WEIGHT_2,
        timestamp,
        actorRef: TRANSPORTER_REF,
        dataHash: HASH_2,
      });
    });

    it("lets a second transporter take over from InTransit", async function () {
      const { mineChain, asRecorder } =
        await networkHelpers.loadFixture(inTransitFixture);
      const timestamp = await nextTimestamp();

      await expect(
        asRecorder.recordHandoff(ID, TRANSPORTER_REF_2, WEIGHT_3, HASH_3),
      )
        .to.emit(mineChain, "HandoffRecorded")
        .withArgs(ID, TRANSPORTER_REF_2, WEIGHT_3, HASH_3, timestamp);

      expectConsignment(await mineChain.getConsignment(ID), {
        stage: Stage.InTransit,
        weightMilligrams: WEIGHT_3,
        timestamp,
        actorRef: TRANSPORTER_REF_2,
        dataHash: HASH_3,
      });
    });

    it("rejects an unknown id with InvalidStage", async function () {
      const { mineChain, asRecorder } =
        await networkHelpers.loadFixture(deployFixture);

      await expect(
        asRecorder.recordHandoff(UNKNOWN_ID, TRANSPORTER_REF, WEIGHT_2, HASH_2),
      )
        .to.be.revertedWithCustomError(mineChain, "InvalidStage")
        .withArgs(UNKNOWN_ID, Stage.None);
    });

    it("rejects a Purchased consignment with InvalidStage", async function () {
      const { mineChain, asRecorder } =
        await networkHelpers.loadFixture(purchasedFixture);

      await expect(
        asRecorder.recordHandoff(ID, TRANSPORTER_REF_2, WEIGHT_4, HASH_4),
      )
        .to.be.revertedWithCustomError(mineChain, "InvalidStage")
        .withArgs(ID, Stage.Purchased);
    });
  });

  describe("recordPurchase", function () {
    it("moves an InTransit consignment to Purchased", async function () {
      const { mineChain, asRecorder } =
        await networkHelpers.loadFixture(inTransitFixture);
      const timestamp = await nextTimestamp();

      await expect(asRecorder.recordPurchase(ID, BUYER_REF, WEIGHT_3, HASH_3))
        .to.emit(mineChain, "PurchaseRecorded")
        .withArgs(ID, BUYER_REF, WEIGHT_3, HASH_3, timestamp);

      expectConsignment(await mineChain.getConsignment(ID), {
        stage: Stage.Purchased,
        weightMilligrams: WEIGHT_3,
        timestamp,
        actorRef: BUYER_REF,
        dataHash: HASH_3,
      });
    });

    it("rejects a Registered consignment with InvalidStage", async function () {
      const { mineChain, asRecorder } =
        await networkHelpers.loadFixture(registeredFixture);

      await expect(asRecorder.recordPurchase(ID, BUYER_REF, WEIGHT_3, HASH_3))
        .to.be.revertedWithCustomError(mineChain, "InvalidStage")
        .withArgs(ID, Stage.Registered);
    });

    it("rejects a second purchase with InvalidStage", async function () {
      const { mineChain, asRecorder } =
        await networkHelpers.loadFixture(purchasedFixture);

      await expect(asRecorder.recordPurchase(ID, BUYER_REF, WEIGHT_4, HASH_4))
        .to.be.revertedWithCustomError(mineChain, "InvalidStage")
        .withArgs(ID, Stage.Purchased);
    });

    it("rejects an unknown id with InvalidStage", async function () {
      const { mineChain, asRecorder } =
        await networkHelpers.loadFixture(deployFixture);

      await expect(
        asRecorder.recordPurchase(UNKNOWN_ID, BUYER_REF, WEIGHT_3, HASH_3),
      )
        .to.be.revertedWithCustomError(mineChain, "InvalidStage")
        .withArgs(UNKNOWN_ID, Stage.None);
    });
  });

  describe("Input validation", function () {
    // Each function starts at a stage where the call would otherwise succeed,
    // so the zero value is the only thing wrong.
    const writeFunctions = [
      {
        name: "registerConsignment",
        fixture: deployFixture,
        actorRef: MINER_REF,
      },
      {
        name: "recordHandoff",
        fixture: registeredFixture,
        actorRef: TRANSPORTER_REF,
      },
      {
        name: "recordPurchase",
        fixture: inTransitFixture,
        actorRef: BUYER_REF,
      },
    ] as const;

    const zeroInputs = [
      {
        label: "id",
        field: InputField.Id,
        args: (actorRef: string) =>
          [ethers.ZeroHash, actorRef, WEIGHT_4, HASH_4] as const,
      },
      {
        label: "actor ref",
        field: InputField.ActorRef,
        args: () => [ID, ethers.ZeroHash, WEIGHT_4, HASH_4] as const,
      },
      {
        label: "weight",
        field: InputField.WeightMilligrams,
        args: (actorRef: string) => [ID, actorRef, 0n, HASH_4] as const,
      },
      {
        label: "dataHash",
        field: InputField.DataHash,
        args: (actorRef: string) =>
          [ID, actorRef, WEIGHT_4, ethers.ZeroHash] as const,
      },
    ];

    for (const { name, fixture, actorRef } of writeFunctions) {
      for (const { label, field, args } of zeroInputs) {
        it(`${name} rejects a zero ${label}`, async function () {
          const { mineChain, asRecorder } =
            await networkHelpers.loadFixture(fixture);

          await expect(asRecorder[name](...args(actorRef)))
            .to.be.revertedWithCustomError(mineChain, "InvalidInput")
            .withArgs(field);
        });
      }
    }
  });

  describe("Check order", function () {
    it("checks the role before the inputs", async function () {
      const { mineChain, stranger, RECORDER_ROLE } =
        await networkHelpers.loadFixture(deployFixture);

      await expect(
        mineChain
          .connect(stranger)
          .registerConsignment(ID, MINER_REF, 0n, HASH_1),
      )
        .to.be.revertedWithCustomError(
          mineChain,
          "AccessControlUnauthorizedAccount",
        )
        .withArgs(stranger.address, RECORDER_ROLE);
    });

    it("checks the inputs before the stage", async function () {
      const { mineChain, asRecorder } =
        await networkHelpers.loadFixture(purchasedFixture);

      await expect(asRecorder.recordHandoff(ID, TRANSPORTER_REF, 0n, HASH_4))
        .to.be.revertedWithCustomError(mineChain, "InvalidInput")
        .withArgs(InputField.WeightMilligrams);
    });
  });

  describe("getConsignment", function () {
    it("returns Stage.None for an unknown id instead of reverting", async function () {
      const { mineChain } = await networkHelpers.loadFixture(deployFixture);

      expectConsignment(await mineChain.getConsignment(UNKNOWN_ID), {
        stage: Stage.None,
        weightMilligrams: 0n,
        timestamp: 0n,
        actorRef: ethers.ZeroHash,
        dataHash: ethers.ZeroHash,
      });
    });
  });

  describe("Full journey", function () {
    // Reads the history the same way the backend will: filter the logs by id,
    // then decode them. Storage only keeps the latest step.
    it("records register, two handoffs and purchase as an ordered history", async function () {
      const { mineChain, asRecorder } =
        await networkHelpers.loadFixture(deployFixture);

      const registeredAt = await nextTimestamp();
      await asRecorder.registerConsignment(ID, MINER_REF, WEIGHT_1, HASH_1);
      const firstHandoffAt = await nextTimestamp();
      await asRecorder.recordHandoff(ID, TRANSPORTER_REF, WEIGHT_2, HASH_2);
      const secondHandoffAt = await nextTimestamp();
      await asRecorder.recordHandoff(ID, TRANSPORTER_REF_2, WEIGHT_3, HASH_3);
      const purchasedAt = await nextTimestamp();
      await asRecorder.recordPurchase(ID, BUYER_REF, WEIGHT_4, HASH_4);

      const logs = await ethers.provider.getLogs({
        address: await mineChain.getAddress(),
        fromBlock: 0,
        toBlock: "latest",
        topics: [null, ID],
      });
      const history = logs.map((log) => {
        const event = mineChain.interface.parseLog(log);
        return [event?.name, ...(event?.args ?? [])];
      });

      expect(history).to.deep.equal([
        ["ConsignmentRegistered", ID, MINER_REF, WEIGHT_1, HASH_1, registeredAt],
        ["HandoffRecorded", ID, TRANSPORTER_REF, WEIGHT_2, HASH_2, firstHandoffAt],
        ["HandoffRecorded", ID, TRANSPORTER_REF_2, WEIGHT_3, HASH_3, secondHandoffAt],
        ["PurchaseRecorded", ID, BUYER_REF, WEIGHT_4, HASH_4, purchasedAt],
      ]);

      expectConsignment(await mineChain.getConsignment(ID), {
        stage: Stage.Purchased,
        weightMilligrams: WEIGHT_4,
        timestamp: purchasedAt,
        actorRef: BUYER_REF,
        dataHash: HASH_4,
      });
    });
  });
});
