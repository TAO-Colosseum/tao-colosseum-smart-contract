/**
 * Check if drand is stored on-chain (Bittensor EVM).
 * Run: npx hardhat run scripts/check-drand.js --network bittensor
 * Optional: CONTRACT_ADDRESS=0x... GAME_ID=1 npx hardhat run scripts/check-drand.js --network bittensor
 */
const hre = require("hardhat");

async function main() {
  const contractAddress = process.env.CONTRACT_ADDRESS || "0x016013CfE6E68590A986C519d869264faa7d2BAB";
  const gameId = process.env.GAME_ID ? parseInt(process.env.GAME_ID, 10) : null;

  console.log("\n=== Drand on-chain check (Bittensor EVM) ===\n");
  console.log("Contract:", contractAddress);
  console.log("Network:", hre.network.name);
  console.log("");

  const colosseum = await hre.ethers.getContractAt("TAOColosseum", contractAddress);

  // 1) Global drand status (is ANY round stored?)
  const [lastRound, isAvailable] = await colosseum.getDrandStatus();
  console.log("--- getDrandStatus() ---");
  console.log("Last stored round on chain:", lastRound.toString());
  console.log("Drand available (lastRound > 0):", isAvailable);
  if (!isAvailable) {
    console.log("\n>>> Drand is NOT being stored on this chain (lastRound == 0).");
    console.log("    The chain may not have the drand pallet / offchain worker feeding pulses.");
    console.log("");
    process.exit(0);
    return;
  }

  // 2) Try to read a specific round (builds pulse key via blake2f precompile)
  const typicalTarget = lastRound + 403n;
  console.log("\n--- Round availability ---");
  console.log("Typical game target (lastRound + 403):", typicalTarget.toString());
  try {
    const available = await colosseum.isDrandRoundAvailable(typicalTarget);
    console.log("Is that round on chain?", available);
    if (!available) {
      console.log(">>> Chain's drand storage may be behind: target round not stored yet.");
    }
  } catch (e) {
    const msg = e.message || e.shortMessage || String(e);
    console.log("isDrandRoundAvailable() failed:", msg);
    if (msg.includes("blake2f")) {
      console.log("\n>>> blake2f precompile failed - Bittensor EVM may not support EIP-152 blake2f.");
      console.log("    Resolution (phase 2) cannot complete; games stay in Calculating until void.");
    }
  }

  // 3) Optional: for a specific game, is its target round available?
  if (gameId != null && !isNaN(gameId)) {
    console.log("\n--- Game " + gameId + " ---");
    let phase, targetDrandRound, actualEndBlock, canFinalize;
    try {
      ({ phase, targetDrandRound, actualEndBlock, canFinalize } = await colosseum.getResolutionStatus(gameId));
    } catch (e) {
      console.log("Game not found or error:", e.message);
      return;
    }
    console.log("Phase:", phase);
    console.log("Target drand round (for this game):", targetDrandRound.toString());
    console.log("Actual end block:", actualEndBlock.toString());
    console.log("Can finalize (pulse for target round exists):", canFinalize);

    const roundAvailable = await colosseum.isDrandRoundAvailable(targetDrandRound);
    console.log("isDrandRoundAvailable(targetRound):", roundAvailable);
    if (!roundAvailable) {
      console.log("\n>>> This game's target round is NOT on chain yet (or never will be).");
      console.log("    If lastRound on chain is much less than targetRound, drand may be lagging or not syncing.");
    }
  }

  console.log("\n=== Done ===\n");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
