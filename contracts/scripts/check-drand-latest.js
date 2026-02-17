/**
 * Test reading the LATEST drand round stored on chain (what games actually use).
 * Usage:
 *   CONTRACT_ADDRESS=0x... npx hardhat run scripts/check-drand-latest.js --network bittensor
 *   CONTRACT_ADDRESS=0x... npx hardhat run scripts/check-drand-latest.js --network bittensorArchive
 */
const hre = require("hardhat");

async function main() {
  const contractAddress = process.env.CONTRACT_ADDRESS || "0x3057113eBACCA66352d7BBa9B92ae09ddeD09C77";

  console.log("\n=== Drand LATEST round test ===\n");
  console.log("Contract:", contractAddress);
  console.log("Network:", hre.network.name);
  console.log("");

  const colosseum = await hre.ethers.getContractAt("TAOColosseum", contractAddress);

  const [lastRound, isAvailable] = await colosseum.getDrandStatus();
  console.log("--- getDrandStatus() ---");
  console.log("Last stored round:", lastRound.toString());
  console.log("Drand available:", isAvailable);
  console.log("");

  if (!isAvailable || lastRound === 0n) {
    console.log(">>> No drand rounds on chain. Cannot test latest.\n");
    process.exit(1);
  }

  const roundAvailable = await colosseum.isDrandRoundAvailable(lastRound);
  console.log("--- isDrandRoundAvailable(lastRound) ---");
  console.log("Round:", lastRound.toString());
  console.log("Available:", roundAvailable);
  console.log("");

  const [exists, randomness] = await colosseum.getDrandRandomness(lastRound);
  console.log("--- getDrandRandomness(lastRound) ---");
  console.log("Exists:", exists);
  console.log("Randomness:", randomness);
  console.log("");

  if (exists && randomness && randomness !== "0x0000000000000000000000000000000000000000000000000000000000000000") {
    console.log("=== PASS: Latest drand round is readable; contract can use it for games ===\n");
  } else {
    console.log("=== FAIL: Latest round not readable. Only hardcoded round 26145524 works; BLAKE2b key for other rounds does not match Substrate. ===\n");
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
