/**
 * Test reading a specific drand round and expected randomness.
 * Usage:
 *   npx hardhat run scripts/check-drand-round.js --network bittensorArchive
 *   ROUND=26145524 EXPECTED=0x228ece1602ca45e06e3a43c336f62fcb8881a4d397b4daa8971f19131d32ee69 npx hardhat run scripts/check-drand-round.js --network bittensorArchive
 */
const hre = require("hardhat");

const ROUND = process.env.ROUND ? BigInt(process.env.ROUND) : 26145524n;
const EXPECTED_RANDOMNESS = process.env.EXPECTED || "0x228ece1602ca45e06e3a43c336f62fcb8881a4d397b4daa8971f19131d32ee69";
const EXPECTED_LAST_ROUND = process.env.LAST_ROUND ? BigInt(process.env.LAST_ROUND) : 26147752n;

async function main() {
  const contractAddress = process.env.CONTRACT_ADDRESS || "0x4660214Da64090Eb0982d107c950865C21bAEa65";

  console.log("\n=== Drand round test ===\n");
  console.log("Contract:", contractAddress);
  console.log("Network:", hre.network.name);
  console.log("Round to read:", ROUND.toString());
  console.log("Expected randomness:", EXPECTED_RANDOMNESS);
  console.log("");

  const colosseum = await hre.ethers.getContractAt("TAOColosseum", contractAddress);

  // 1) Last stored round
  const [lastRound, isAvailable] = await colosseum.getDrandStatus();
  console.log("--- getDrandStatus() ---");
  console.log("Last stored round:", lastRound.toString());
  console.log("Drand available:", isAvailable);
  const lastMatch = lastRound === EXPECTED_LAST_ROUND;
  console.log("Matches expected last round (" + EXPECTED_LAST_ROUND + ")?", lastMatch);
  if (!lastMatch) {
    console.log("(Optional: set LAST_ROUND=" + lastRound + " to match current chain)");
  }
  console.log("");

  // 2) Is this round available?
  const roundAvailable = await colosseum.isDrandRoundAvailable(ROUND);
  console.log("--- isDrandRoundAvailable(" + ROUND + ") ---");
  console.log("Available:", roundAvailable);
  console.log("");

  // 3) Get randomness for this round
  const [exists, randomness] = await colosseum.getDrandRandomness(ROUND);
  console.log("--- getDrandRandomness(" + ROUND + ") ---");
  console.log("Exists:", exists);
  console.log("Randomness:", randomness);
  const expectedHex = EXPECTED_RANDOMNESS.toLowerCase().replace(/^0x/, "");
  const actualHex = randomness ? randomness.toLowerCase().replace(/^0x/, "") : "";
  const match = exists && actualHex === expectedHex;
  console.log("Matches expected randomness?", match);
  if (!match && exists) {
    console.log("Expected:", EXPECTED_RANDOMNESS);
    console.log("Got:     0x" + actualHex);
  }
  console.log("");

  if (match) {
    console.log("=== PASS: Round " + ROUND + " randomness matches ===\n");
  } else {
    console.log("=== FAIL or partial: round not readable or randomness mismatch ===\n");
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
