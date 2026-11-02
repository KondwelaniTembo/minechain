import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("MineChainModule", (m) => {
  // No default value: a missing parameter must stop the deploy rather than
  // grant the role to a fallback address.
  const recorder = m.getParameter<string>("recorder");

  // The deployer only becomes admin. It is not granted RECORDER_ROLE, so the
  // admin key never has to sit on the server alongside the recorder wallet.
  const mineChain = m.contract("MineChain");

  // Read the role from the deployed contract instead of recomputing the hash
  // here, so the module cannot drift from the Solidity definition.
  const recorderRole = m.staticCall(mineChain, "RECORDER_ROLE");
  m.call(mineChain, "grantRole", [recorderRole, recorder]);

  return { mineChain };
});
