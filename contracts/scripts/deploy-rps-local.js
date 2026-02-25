/**
 * Deploy RPS_Tournament to local Hardhat network (no prompt, no real TAO).
 * Use with: npx hardhat run scripts/deploy-rps-local.js
 * Then: RPS_CONTRACT_ADDRESS=<address> npx hardhat run scripts/check-rps-tournaments.js
 */
const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  const RPS = await hre.ethers.getContractFactory("RPS_Tournament");
  const rps = await RPS.deploy();
  await rps.waitForDeployment();
  const address = await rps.getAddress();
  console.log("RPS_Tournament deployed at:", address);
  console.log("");
  console.log("To check state:");
  console.log("  RPS_CONTRACT_ADDRESS=" + address + " npx hardhat run scripts/check-rps-tournaments.js");
  console.log("");
  console.log("DEPLOYED_RPS_ADDRESS=" + address);
}

main()
  .then(() => process.exit(0))
  .catch((e) => { console.error(e); process.exit(1); });
