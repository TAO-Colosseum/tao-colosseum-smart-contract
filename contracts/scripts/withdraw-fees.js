/**
 * Withdraw all accumulated platform fees from TAO Colosseum.
 * Only the contract owner can call withdrawFees().
 *
 * Usage:
 *   CONTRACT_ADDRESS=0x... npx hardhat run scripts/withdraw-fees.js [--network <name>]
 *
 * Example:
 *   CONTRACT_ADDRESS=0x016013CfE6E68590A986C519d869264faa7d2BAB npx hardhat run scripts/withdraw-fees.js --network bittensor
 */
const hre = require("hardhat");

async function main() {
  const contractAddress = process.env.CONTRACT_ADDRESS;
  if (!contractAddress) {
    console.error("Usage: CONTRACT_ADDRESS=0x... npx hardhat run scripts/withdraw-fees.js [--network <name>]");
    process.exit(1);
  }

  console.log("\n=== TAO Colosseum – Withdraw Fees ===\n");
  console.log("Contract:", contractAddress);
  console.log("Network:", hre.network.name);
  console.log("");

  const [signer] = await hre.ethers.getSigners();
  console.log("Signer (must be owner):", signer.address);

  const colosseum = await hre.ethers.getContractAt("TAOColosseum", contractAddress);
  const owner = await colosseum.owner();
  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    console.error("\nError: Signer is not the contract owner. Owner:", owner);
    process.exit(1);
  }

  const accumulated = await colosseum.getAccumulatedFees();
  if (accumulated === 0n) {
    console.log("\nNo fees to withdraw (accumulatedFees is 0).");
    process.exit(0);
  }

  console.log("Accumulated fees:", hre.ethers.formatEther(accumulated), "TAO");
  console.log("\nSending withdrawFees()...");

  const tx = await colosseum.withdrawFees();
  console.log("Transaction hash:", tx.hash);
  await tx.wait();
  console.log("Confirmed.\n");

  const after = await colosseum.getAccumulatedFees();
  console.log("Accumulated fees after withdraw:", hre.ethers.formatEther(after), "TAO");
  console.log("\nDone.");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
