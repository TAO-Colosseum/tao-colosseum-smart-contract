/**
 * Call flushFeesToSubnetAndBurn() on RPS_Tournament.
 * Usage: RPS_CONTRACT_ADDRESS=0x... npx hardhat run scripts/flush-rps-fees.js [--network bittensorTestnet]
 */
const hre = require("hardhat");

async function main() {
  const address = process.env.RPS_CONTRACT_ADDRESS;
  if (!address) {
    console.error("Set RPS_CONTRACT_ADDRESS=0x...");
    process.exit(1);
  }

  const rps = await hre.ethers.getContractAt("RPS_Tournament", address);
  const fees = await rps.accumulatedFees();

  if (fees === 0n) {
    console.log("No accumulated fees. Exiting.");
    return;
  }

  console.log("Accumulated fees:", hre.ethers.formatEther(fees), "TAO");
  console.log("Calling flushFeesToSubnetAndBurn()...");

  const tx = await rps.flushFeesToSubnetAndBurn();
  await tx.wait();
  console.log("Tx hash:", tx.hash);
  console.log("Done.");
}

main().catch((e) => { console.error(e); process.exit(1); });
